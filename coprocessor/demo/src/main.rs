//! End-to-end checks of the local coprocessor through the real path: a contract on the
//! host chain does FHE operations and marks the results publicly decryptable; host-listener
//! turns the events into computations, tfhe-worker computes, sns-worker uploads the
//! ciphertext to the bucket and transaction-sender commits its digest on the gateway.
//! This program then asks the gateway's Decryption contract for a public decryption; the
//! KMS (through kms-connector) fetches the ciphertext, checks the host ACL, decrypts, and
//! answers on the gateway chain, where the value is read back and compared.
//!
//! SCENARIO=add       Add.sol: 3 + 5 in one transaction (default)
//! SCENARIO=transfer  PracticeToken (upstream EncryptedERC20): mint, a transfer that fits,
//!                    a transfer that does not; both balances must come out right
//!
//! Nothing here holds a decryption key. The only way to a cleartext is the KMS, and the
//! KMS only answers for handles the host ACL allowed for decryption.

use std::time::{Duration, Instant};

use alloy::network::{EthereumWallet, TransactionBuilder};
use alloy::primitives::utils::format_ether;
use alloy::primitives::{address, Address, Bytes, FixedBytes, B256, U256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::{Filter, TransactionRequest};
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use alloy::sol_types::{SolConstructor, SolEvent};
use anyhow::{anyhow, Context, Result};
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
        function reveal(address account) external;
    }

    // host chain
    #[sol(rpc)]
    contract ACL {
        function isAllowedForDecryption(bytes32 handle) external view returns (bool);
    }

    // gateway chain
    #[sol(rpc)]
    contract CiphertextCommits {
        function isCiphertextMaterialAdded(bytes32 ctHandle) external view returns (bool);
    }

    #[sol(rpc)]
    contract Decryption {
        event PublicDecryptionRequest(uint256 indexed decryptionId, bytes32[] ctHandles, bytes extraData);
        event PublicDecryptionResponse(uint256 indexed decryptionId, bytes decryptedResult, bytes[] signatures, bytes extraData);
        function publicDecryptionRequest(bytes32[] ctHandles, bytes extraData) external;
    }

    #[sol(rpc)]
    contract ProtocolPayment {
        function getPublicDecryptionPrice() external view returns (uint256);
    }

    #[sol(rpc)]
    contract ZamaOFT {
        function balanceOf(address account) external view returns (uint256);
        function allowance(address owner, address spender) external view returns (uint256);
        function mint(address to, uint256 amount) external;
        function approve(address spender, uint256 amount) external returns (bool);
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

fn short(handle: &FixedBytes<32>) -> String {
    hex::encode(&handle[..6])
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

struct Ctx<P> {
    host: P,
    gateway: P,
    pool: PgPool,
    sender: Address,
    acl: Address,
    executor: Address,
    kms: Address,
    decryption: Address,
    payment: Address,
    commits: Address,
    zama: Address,
}

/// tfhe-worker stored a ciphertext for the handle (only outputs somebody is allowed to read
/// get computed at all).
async fn computed(pool: &PgPool, handle: FixedBytes<32>) -> Result<()> {
    let t0 = Instant::now();
    let (len, ct_type) = wait_for("ciphertext", Duration::from_secs(180), || {
        let pool = pool.clone();
        let h = handle.to_vec();
        async move {
            Ok(sqlx::query_as::<_, (i32, i16)>(
                "SELECT length(ciphertext), ciphertext_type FROM ciphertexts WHERE handle = $1 ORDER BY ciphertext_version DESC LIMIT 1",
            )
            .bind(h)
            .fetch_optional(&pool)
            .await?)
        }
    })
    .await?;
    println!("  {} computed after {:.1}s ({len} bytes, type {ct_type})", short(&handle), t0.elapsed().as_secs_f32());
    Ok(())
}

/// sns-worker squashed and uploaded it, transaction-sender committed the digest on the gateway.
async fn committed<P: Provider + Clone>(c: &Ctx<P>, handle: FixedBytes<32>) -> Result<()> {
    let t0 = Instant::now();
    let (d64, d128) = wait_for("ciphertext_digest", Duration::from_secs(240), || {
        let pool = c.pool.clone();
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
    .await?;
    println!(
        "  {} uploaded after {:.1}s  digest64={} digest128={}",
        short(&handle), t0.elapsed().as_secs_f32(), hex::encode(&d64[..8]), hex::encode(&d128[..8])
    );
    let commits = CiphertextCommits::new(c.commits, c.gateway.clone());
    wait_for("CiphertextCommits on the gateway", Duration::from_secs(240), || {
        let commits = commits.clone();
        async move { Ok(commits.isCiphertextMaterialAdded(handle).call().await?.then_some(())) }
    })
    .await?;
    println!("  {} committed on the gateway after {:.1}s", short(&handle), t0.elapsed().as_secs_f32());
    Ok(())
}

/// The gateway charges each request in ZAMA. On this local chain the token is the upstream
/// mock that anyone can mint, and the sender is not one of the gateway anvil's funded
/// accounts, so it gives itself gas the anvil way. Neither happens on a real network.
async fn pay<P: Provider + Clone>(c: &Ctx<P>) -> Result<()> {
    if c.gateway.get_balance(c.sender).await? < U256::from(10u128.pow(18)) {
        c.gateway
            .raw_request::<_, serde_json::Value>("anvil_setBalance".into(), (c.sender, "0x3635C9ADC5DEA00000"))
            .await
            .context("anvil_setBalance on the gateway chain")?;
    }
    let price = ProtocolPayment::new(c.payment, c.gateway.clone()).getPublicDecryptionPrice().call().await?;
    let token = ZamaOFT::new(c.zama, c.gateway.clone());
    if token.balanceOf(c.sender).call().await? < price {
        token.mint(c.sender, price).send().await.context("mint ZAMA")?.get_receipt().await?;
    }
    if token.allowance(c.sender, c.payment).call().await? < price {
        token.approve(c.payment, U256::MAX).send().await.context("approve ProtocolPayment")?.get_receipt().await?;
    }
    println!("  fee {} ZAMA (mocked token, minted here)", format_ether(price));
    Ok(())
}

/// One public decryption request on the gateway for all the handles; the KMS's answer is an
/// event on the same contract, its decryptedResult abi-encodes one uint256 per handle.
async fn public_decrypt<P: Provider + Clone>(c: &Ctx<P>, handles: Vec<FixedBytes<32>>) -> Result<Vec<U256>> {
    pay(c).await?;
    let decryption = Decryption::new(c.decryption, c.gateway.clone());
    let receipt = decryption
        .publicDecryptionRequest(handles.clone(), Bytes::new())
        .send()
        .await
        .context("publicDecryptionRequest")?
        .get_receipt()
        .await?;
    if !receipt.status() {
        return Err(anyhow!("publicDecryptionRequest reverted in tx {}", receipt.transaction_hash));
    }
    let id = receipt
        .logs()
        .iter()
        .find_map(|l| Decryption::PublicDecryptionRequest::decode_log(l.as_ref()).ok())
        .map(|e| e.decryptionId)
        .ok_or_else(|| anyhow!("no PublicDecryptionRequest event in receipt"))?;
    let from = receipt.block_number.unwrap_or_default();
    println!("publicDecryptionRequest #{id} tx {} gateway block {from}", receipt.transaction_hash);

    let t0 = Instant::now();
    let filter = Filter::new()
        .address(c.decryption)
        .event_signature(Decryption::PublicDecryptionResponse::SIGNATURE_HASH)
        .topic1(B256::from(id))
        .from_block(from);
    let response = wait_for("PublicDecryptionResponse from the KMS", Duration::from_secs(300), || {
        let gateway = c.gateway.clone();
        let filter = filter.clone();
        async move {
            let logs = gateway.get_logs(&filter).await?;
            Ok(logs.iter().find_map(|l| Decryption::PublicDecryptionResponse::decode_log(l.as_ref()).ok()))
        }
    })
    .await?;
    println!(
        "  KMS answered after {:.1}s: {} signature(s), {} bytes",
        t0.elapsed().as_secs_f32(), response.signatures.len(), response.decryptedResult.len()
    );
    let words: Vec<U256> = response.decryptedResult.chunks_exact(32).map(U256::from_be_slice).collect();
    if words.len() != handles.len() {
        return Err(anyhow!("expected {} values in decryptedResult, got {}", handles.len(), words.len()));
    }
    Ok(words)
}

async fn scenario_add<P: Provider + Clone>(c: &Ctx<P>) -> Result<()> {
    let (x, y) = (env_num("X", 3u8), env_num("Y", 5u8));
    let ctor = Add::constructorCall { acl: c.acl, executor: c.executor, kmsVerifier: c.kms }.abi_encode();
    let at = deploy(&c.host, bytecode("ADD_ARTIFACT", "/app/Add.json")?, ctor).await?;
    println!("Add deployed at {at}");

    // one transaction: encrypt x, encrypt y, add, allow the sender, allow public decryption
    let contract = Add::new(at, c.host.clone());
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

    computed(&c.pool, handle).await?;
    committed(c, handle).await?;
    let value = public_decrypt(c, vec![handle]).await?.remove(0);
    println!("decrypt = {value}");
    if value != U256::from(x as u16 + y as u16) {
        return Err(anyhow!("expected {}, got {value}", x as u16 + y as u16));
    }
    println!("OK: {x} + {y} = {value} (computed by the coprocessor, decrypted by the KMS)");
    Ok(())
}

async fn scenario_transfer<P: Provider + Clone>(c: &Ctx<P>) -> Result<()> {
    let (minted, amount, too_much) = (env_num("MINT", 1000u64), env_num("AMOUNT", 250u64), env_num("TOO_MUCH", 900u64));
    let ctor = PracticeToken::constructorCall { acl: c.acl, executor: c.executor, kmsVerifier: c.kms }.abi_encode();
    let at = deploy(&c.host, bytecode("TOKEN_ARTIFACT", "/app/PracticeToken.json")?, ctor).await?;
    println!("PracticeToken deployed at {at}");
    let token = PracticeToken::new(at, c.host.clone());

    let r = token.mint(minted).send().await.context("mint")?.get_receipt().await?;
    println!("mint({minted}) tx {} block {}", r.transaction_hash, r.block_number.unwrap_or_default());
    let r = token.transferPlain(RECIPIENT, amount).send().await.context("transfer")?.get_receipt().await?;
    println!("transferPlain({amount}) tx {} block {}", r.transaction_hash, r.block_number.unwrap_or_default());
    // more than the balance: the contract transfers an encrypted 0 instead, and the chain
    // shows the same Transfer event either way
    let r = token.transferPlain(RECIPIENT, too_much).send().await.context("transfer too much")?.get_receipt().await?;
    println!("transferPlain({too_much}) tx {} block {} (should not change balances)", r.transaction_hash, r.block_number.unwrap_or_default());

    let h_sender = token.balanceOf(c.sender).call().await?;
    let h_recipient = token.balanceOf(RECIPIENT).call().await?;
    println!("balance handles: sender {}  recipient {}", hex::encode(h_sender), hex::encode(h_recipient));

    // the ACL gate: a balance is private until the contract says otherwise
    let acl = ACL::new(c.acl, c.host.clone());
    println!("ACL allows public decryption of the sender balance: {}", acl.isAllowedForDecryption(h_sender).call().await?);
    for account in [c.sender, RECIPIENT] {
        token.reveal(account).send().await.context("reveal")?.get_receipt().await?;
    }
    println!("after reveal: {}", acl.isAllowedForDecryption(h_sender).call().await?);

    computed(&c.pool, h_sender).await?;
    computed(&c.pool, h_recipient).await?;
    committed(c, h_sender).await?;
    committed(c, h_recipient).await?;
    let values = public_decrypt(c, vec![h_sender, h_recipient]).await?;
    println!("decrypt: sender = {}  recipient = {}", values[0], values[1]);
    let (exp_s, exp_r) = (U256::from(minted - amount), U256::from(amount));
    if values[0] != exp_s || values[1] != exp_r {
        return Err(anyhow!("expected {exp_s}/{exp_r}, got {}/{}", values[0], values[1]));
    }
    println!("OK: {minted} minted, {amount} transferred, {too_much} refused silently: {} / {}", values[0], values[1]);
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let signer: PrivateKeySigner = env("PRIVATE_KEY")?.parse().context("PRIVATE_KEY")?;
    let sender = signer.address();
    let connect = |name: &str| -> Result<_> {
        Ok(ProviderBuilder::new()
            .wallet(EthereumWallet::from(signer.clone()))
            .connect_http(env(name)?.parse().with_context(|| name.to_string())?))
    };
    let host = connect("RPC_URL")?;
    let gateway = connect("GATEWAY_RPC_URL")?;
    let pool = PgPool::connect(&env("DATABASE_URL")?).await.context("connect")?;
    println!(
        "host chain {} block {}, gateway chain {} block {}, sender {sender}",
        host.get_chain_id().await?, host.get_block_number().await?,
        gateway.get_chain_id().await?, gateway.get_block_number().await?
    );
    let c = Ctx {
        host,
        gateway,
        pool,
        sender,
        acl: addr("ACL_ADDRESS")?,
        executor: addr("FHEVM_EXECUTOR_ADDRESS")?,
        kms: addr("KMS_VERIFIER_ADDRESS")?,
        decryption: addr("DECRYPTION_ADDRESS")?,
        payment: addr("PROTOCOL_PAYMENT_ADDRESS")?,
        commits: addr("CIPHERTEXT_COMMITS_ADDRESS")?,
        zama: addr("ZAMA_OFT_ADDRESS")?,
    };
    match std::env::var("SCENARIO").as_deref().unwrap_or("add") {
        "add" => scenario_add(&c).await,
        "transfer" => scenario_transfer(&c).await,
        other => Err(anyhow!("unknown SCENARIO {other} (add | transfer)")),
    }
}
