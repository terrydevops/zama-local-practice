//! End-to-end checks of the local coprocessor through the real path: a contract on the
//! host chain does FHE operations and allows the caller to read the results; host-listener
//! turns the events into computations, tfhe-worker computes, sns-worker uploads; this
//! program follows the result handles from the chain into the coprocessor database and
//! decrypts them with the test client key.
//!
//! SCENARIO=add       Add.sol: 3 + 5 in one transaction (default)
//! SCENARIO=transfer  PracticeToken (upstream EncryptedERC20): mint, a transfer that fits,
//!                    a transfer that does not; both balances must come out right
//!
//! Decryption with the client key is only possible with the test keyset; on a real network
//! that key lives inside the KMS.

use std::time::{Duration, Instant};

use alloy::network::{EthereumWallet, TransactionBuilder};
use alloy::primitives::{address, Address, Bytes, FixedBytes};
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

    #[sol(rpc)]
    contract PracticeToken {
        event Transfer(address indexed from, address indexed to);
        event Mint(address indexed to, uint64 amount);
        constructor(address acl, address executor, address kmsVerifier);
        function mint(uint64 mintedAmount) external;
        function transferPlain(address to, uint64 amount) external returns (bool);
        function balanceOf(address wallet) external view returns (bytes32);
    }
}

/// Somebody to send tokens to; only its balance handle is read, it never signs anything.
const RECIPIENT: Address = address!("1111111111111111111111111111111111111111");

fn env(name: &str) -> Result<String> {
    std::env::var(name).with_context(|| format!("{name} is not set"))
}

fn addr(name: &str) -> Result<Address> {
    env(name)?.parse().with_context(|| format!("{name} is not an address"))
}

fn env_num<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// Creation bytecode from a forge artifact (ADD_ARTIFACT / TOKEN_ARTIFACT, /app/*.json in the image).
fn bytecode(env_name: &str, default: &str) -> Result<Bytes> {
    let path = std::env::var(env_name).unwrap_or_else(|_| default.into());
    let json: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).with_context(|| format!("read {path}"))?)?;
    let code = json["bytecode"]["object"].as_str().ok_or_else(|| anyhow!("no bytecode in {path}"))?;
    code.parse().context("bytecode hex")
}

async fn deploy<P: Provider>(provider: &P, code: Bytes, ctor_args: Vec<u8>) -> Result<Address> {
    let mut init = code.to_vec();
    init.extend(ctor_args);
    let receipt = provider
        .send_transaction(TransactionRequest::default().with_deploy_code(init))
        .await
        .context("deploy")?
        .get_receipt()
        .await?;
    receipt.contract_address.ok_or_else(|| anyhow!("deploy tx has no contract address"))
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

/// The ciphertext tfhe-worker stored for a handle (only outputs somebody is allowed to read
/// get computed at all).
async fn ciphertext(pool: &PgPool, handle: FixedBytes<32>) -> Result<(Vec<u8>, i16)> {
    let version = current_ciphertext_version();
    let t0 = Instant::now();
    let (ct, ct_type) = wait_for("ciphertext", Duration::from_secs(180), || {
        let pool = pool.clone();
        let h = handle.to_vec();
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
    println!("  {} computed after {:.1}s ({} bytes, type {ct_type})", hex::encode(&handle[..6]), t0.elapsed().as_secs_f32(), ct.len());
    Ok((ct, ct_type))
}

/// Decrypt with the test client key from the keys table.
async fn decrypt(pool: &PgPool, cts: Vec<(Vec<u8>, i16)>) -> Result<Vec<String>> {
    let keys = DbKeyCache::new_with_force_legacy(4, false)?;
    let key = keys.fetch_latest_from_pool(pool).await?;
    let cks = key.cks.ok_or_else(|| anyhow!("no client key in keys table (not a test keyset)"))?;
    tokio::task::spawn_blocking(move || -> Result<Vec<String>> {
        tfhe::set_server_key(key.sks);
        cts.into_iter()
            .map(|(ct, t)| Ok(SupportedFheCiphertexts::decompress_no_memcheck(t, &ct)?.decrypt(&cks)))
            .collect()
    })
    .await?
}

/// sns-worker: squash, upload, digest. Reported, not required.
async fn report_upload(pool: &PgPool, handle: FixedBytes<32>) {
    let t1 = Instant::now();
    let digest = wait_for("ciphertext_digest", Duration::from_secs(240), || {
        let pool = pool.clone();
        let h = handle.to_vec();
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
            "  {} uploaded after {:.1}s  digest64={} digest128={}",
            hex::encode(&handle[..6]), t1.elapsed().as_secs_f32(), hex::encode(&d64[..8]), hex::encode(&d128[..8])),
        Err(e) => println!("  (sns/upload not observed: {e})"),
    }
}

struct Ctx<P> {
    provider: P,
    pool: PgPool,
    acl: Address,
    executor: Address,
    kms: Address,
}

async fn scenario_add<P: Provider + Clone>(c: &Ctx<P>) -> Result<()> {
    let (x, y) = (env_num("X", 3u8), env_num("Y", 5u8));
    let ctor = Add::constructorCall { acl: c.acl, executor: c.executor, kmsVerifier: c.kms }.abi_encode();
    let at = deploy(&c.provider, bytecode("ADD_ARTIFACT", "/app/Add.json")?, ctor).await?;
    println!("Add deployed at {at}");

    // one transaction: encrypt x, encrypt y, add, allow the sender
    let contract = Add::new(at, &c.provider);
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

    let ct = ciphertext(&c.pool, handle).await?;
    let value = decrypt(&c.pool, vec![ct]).await?.remove(0);
    println!("decrypt = {value}");
    let expected = (x as u16 + y as u16).to_string();
    if value != expected {
        return Err(anyhow!("expected {expected}, got {value}"));
    }
    report_upload(&c.pool, handle).await;
    println!("OK: {x} + {y} = {value} (on chain)");
    Ok(())
}

async fn scenario_transfer<P: Provider + Clone>(c: &Ctx<P>, sender: Address) -> Result<()> {
    let (minted, amount, too_much) = (env_num("MINT", 1000u64), env_num("AMOUNT", 250u64), env_num("TOO_MUCH", 900u64));
    let ctor = PracticeToken::constructorCall { acl: c.acl, executor: c.executor, kmsVerifier: c.kms }.abi_encode();
    let at = deploy(&c.provider, bytecode("TOKEN_ARTIFACT", "/app/PracticeToken.json")?, ctor).await?;
    println!("PracticeToken deployed at {at}");
    let token = PracticeToken::new(at, &c.provider);

    let r = token.mint(minted).send().await.context("mint")?.get_receipt().await?;
    println!("mint({minted}) tx {} block {}", r.transaction_hash, r.block_number.unwrap_or_default());
    let r = token.transferPlain(RECIPIENT, amount).send().await.context("transfer")?.get_receipt().await?;
    println!("transferPlain({amount}) tx {} block {}", r.transaction_hash, r.block_number.unwrap_or_default());
    // more than the balance: the contract transfers an encrypted 0 instead, and the chain
    // shows the same Transfer event either way
    let r = token.transferPlain(RECIPIENT, too_much).send().await.context("transfer too much")?.get_receipt().await?;
    println!("transferPlain({too_much}) tx {} block {} (should not change balances)", r.transaction_hash, r.block_number.unwrap_or_default());

    let h_sender = token.balanceOf(sender).call().await?;
    let h_recipient = token.balanceOf(RECIPIENT).call().await?;
    println!("balance handles: sender {}  recipient {}", hex::encode(h_sender), hex::encode(h_recipient));

    let ct_s = ciphertext(&c.pool, h_sender).await?;
    let ct_r = ciphertext(&c.pool, h_recipient).await?;
    let values = decrypt(&c.pool, vec![ct_s, ct_r]).await?;
    println!("decrypt: sender = {}  recipient = {}", values[0], values[1]);
    let (exp_s, exp_r) = ((minted - amount).to_string(), amount.to_string());
    if values[0] != exp_s || values[1] != exp_r {
        return Err(anyhow!("expected {exp_s}/{exp_r}, got {}/{}", values[0], values[1]));
    }
    report_upload(&c.pool, h_sender).await;
    report_upload(&c.pool, h_recipient).await;
    println!("OK: {minted} minted, {amount} transferred, {too_much} refused silently: {} / {}", values[0], values[1]);
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let signer: PrivateKeySigner = env("PRIVATE_KEY")?.parse().context("PRIVATE_KEY")?;
    let sender = signer.address();
    let provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(signer))
        .connect_http(env("RPC_URL")?.parse().context("RPC_URL")?);
    let pool = PgPool::connect(&env("DATABASE_URL")?).await.context("connect")?;
    let chain = provider.get_chain_id().await?;
    let block = provider.get_block_number().await?;
    println!("chain {chain} block {block}, sender {sender}");
    let c = Ctx {
        provider,
        pool,
        acl: addr("ACL_ADDRESS")?,
        executor: addr("FHEVM_EXECUTOR_ADDRESS")?,
        kms: addr("KMS_VERIFIER_ADDRESS")?,
    };
    match std::env::var("SCENARIO").as_deref().unwrap_or("add") {
        "add" => scenario_add(&c).await,
        "transfer" => scenario_transfer(&c, sender).await,
        other => Err(anyhow!("unknown SCENARIO {other} (add | transfer)")),
    }
}
