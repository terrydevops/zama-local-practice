//! End-to-end check of the local coprocessor through the real path: deploy Add.sol on the
//! host chain, send add(3, 5), follow the result handle from the transaction receipt into
//! the coprocessor database, decrypt it with the test client key and print the sum.
//!
//! The contract encrypts both numbers, adds them and allows the caller to read the result
//! in one transaction; host-listener turns the events into computations, tfhe-worker computes
//! the sum, sns-worker uploads it. Decryption with the client key is only possible with the
//! test keyset; on a real network that key lives inside the KMS.

use std::time::{Duration, Instant};

use alloy::network::{EthereumWallet, TransactionBuilder};
use alloy::primitives::{Address, Bytes, FixedBytes};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::TransactionRequest;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use alloy::sol_types::{SolConstructor, SolEvent};
use anyhow::{anyhow, Context, Result};
use fhevm_engine_common::db_keys::DbKeyCache;
use fhevm_engine_common::tfhe_ops::current_ciphertext_version;
use fhevm_engine_common::types::SupportedFheCiphertexts;
use sqlx::PgPool;

sol! {
    #[sol(rpc)]
    contract Add {
        event Sum(address indexed caller, bytes32 handle);
        constructor(address acl, address executor, address kmsVerifier);
        function add(uint8 a, uint8 b) external returns (bytes32 handle);
    }
}

fn env(name: &str) -> Result<String> {
    std::env::var(name).with_context(|| format!("{name} is not set"))
}

fn addr(name: &str) -> Result<Address> {
    env(name)?.parse().with_context(|| format!("{name} is not an address"))
}

async fn wait_for<T, F, Fut>(what: &str, timeout: Duration, mut f: F) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<Option<T>>>,
{
    let start = Instant::now();
    loop {
        if let Some(v) = f().await? {
            return Ok(v);
        }
        if start.elapsed() > timeout {
            return Err(anyhow!("timed out waiting for {what}"));
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let (x, y) = (
        std::env::var("X").ok().and_then(|v| v.parse::<u8>().ok()).unwrap_or(3),
        std::env::var("Y").ok().and_then(|v| v.parse::<u8>().ok()).unwrap_or(5),
    );
    let rpc = env("RPC_URL")?;
    let signer: PrivateKeySigner = env("PRIVATE_KEY")?.parse().context("PRIVATE_KEY")?;
    let sender = signer.address();
    let provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(signer))
        .connect_http(rpc.parse().context("RPC_URL")?);
    let pool = PgPool::connect(&env("DATABASE_URL")?).await.context("connect")?;

    // 1. deploy Add.sol, bytecode from the forge artifact built into the image
    let artifact = std::env::var("ADD_ARTIFACT").unwrap_or_else(|_| "/app/Add.json".into());
    let json: serde_json::Value = serde_json::from_slice(&std::fs::read(&artifact)
        .with_context(|| format!("read {artifact}"))?)?;
    let code = json["bytecode"]["object"].as_str().ok_or_else(|| anyhow!("no bytecode in {artifact}"))?;
    let code: Bytes = code.parse().context("bytecode hex")?;
    let (acl, executor, kms) = (addr("ACL_ADDRESS")?, addr("FHEVM_EXECUTOR_ADDRESS")?, addr("KMS_VERIFIER_ADDRESS")?);
    let chain = provider.get_chain_id().await?;
    let block = provider.get_block_number().await?;
    println!("chain {chain} block {block}, sender {sender}");
    let mut init = code.to_vec();
    init.extend(Add::constructorCall { acl, executor, kmsVerifier: kms }.abi_encode());
    let receipt = provider
        .send_transaction(TransactionRequest::default().with_deploy_code(init))
        .await
        .context("deploy Add")?
        .get_receipt()
        .await?;
    let contract_addr = receipt.contract_address.ok_or_else(|| anyhow!("deploy tx has no contract address"))?;
    println!("Add deployed at {contract_addr}");

    // 2. one transaction: encrypt x, encrypt y, add, allow the sender
    let contract = Add::new(contract_addr, &provider);
    let receipt = contract.add(x, y).send().await.context("send add")?.get_receipt().await?;
    if !receipt.status() {
        return Err(anyhow!("add({x}, {y}) reverted in tx {}", receipt.transaction_hash));
    }
    let handle = receipt
        .logs()
        .iter()
        .find_map(|l| Add::Sum::decode_log(l.as_ref()).ok())
        .map(|e| e.handle)
        .ok_or_else(|| anyhow!("no Sum event in receipt"))?;
    println!("tx {} in block {}", receipt.transaction_hash, receipt.block_number.unwrap_or_default());
    println!("{x} + {y} -> handle {}", hex::encode(handle));

    // 3. host-listener writes the computation, tfhe-worker computes the ciphertext
    let version = current_ciphertext_version();
    let t0 = Instant::now();
    let h: FixedBytes<32> = handle;
    let (ct, ct_type): (Vec<u8>, i16) = wait_for("ciphertext", Duration::from_secs(180), || {
        let pool = pool.clone();
        let h = h.to_vec();
        async move {
            Ok(sqlx::query_as::<_, (Vec<u8>, i16)>(
                "SELECT ciphertext, ciphertext_type FROM ciphertexts WHERE handle = $1 AND ciphertext_version = $2",
            )
            .bind(h)
            .bind(version)
            .fetch_optional(&pool)
            .await?)
        }
    })
    .await?;
    println!("computed after {:.1}s ({} bytes, type {ct_type})", t0.elapsed().as_secs_f32(), ct.len());

    // 4. decrypt with the test client key
    let keys = DbKeyCache::new_with_force_legacy(4, false)?;
    let key = keys.fetch_latest_from_pool(&pool).await?;
    let cks = key.cks.ok_or_else(|| anyhow!("no client key in keys table (not a test keyset)"))?;
    let value = tokio::task::spawn_blocking(move || -> Result<String> {
        tfhe::set_server_key(key.sks);
        let ct = SupportedFheCiphertexts::decompress_no_memcheck(ct_type, &ct)?;
        Ok(ct.decrypt(&cks))
    })
    .await??;
    println!("decrypt = {value}");
    if value != (x as u16 + y as u16).to_string() {
        return Err(anyhow!("expected {}, got {value}", x as u16 + y as u16));
    }

    // 5. sns-worker: squash, upload, digest
    let t1 = Instant::now();
    let digest = wait_for("ciphertext_digest", Duration::from_secs(240), || {
        let pool = pool.clone();
        let h = h.to_vec();
        async move {
            Ok(sqlx::query_as::<_, (Option<Vec<u8>>, Option<Vec<u8>>)>(
                "SELECT ciphertext, ciphertext128 FROM ciphertext_digest WHERE handle = $1",
            )
            .bind(h)
            .fetch_optional(&pool)
            .await?
            .and_then(|(d64, d128)| Some((d64?, d128?))))
        }
    })
    .await;
    match digest {
        Ok((d64, d128)) => println!(
            "uploaded after {:.1}s  digest64={} digest128={}",
            t1.elapsed().as_secs_f32(), hex::encode(&d64[..8]), hex::encode(&d128[..8])),
        Err(e) => println!("(sns/upload not observed: {e})"),
    }
    println!("OK: {x} + {y} = {value} (on chain)");
    Ok(())
}
