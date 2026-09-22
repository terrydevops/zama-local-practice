//! Smallest possible end-to-end check of the local coprocessor: encrypt 3 and 5,
//! ask for their sum, wait for tfhe-worker to compute it, decrypt the result with
//! the test client key and print it.
//!
//! The three FHE events are written the same way host-listener writes them for a
//! real block (through host_listener's Database), so the rows look exactly like
//! production rows. Decryption with the client key is only possible with the test
//! keyset; on a real network that key lives inside the KMS.

use std::time::{Duration, Instant};

use alloy::primitives::{Address, FixedBytes, Log, U256};
use anyhow::{anyhow, Context, Result};
use fhevm_engine_common::chain_id::ChainId;
use fhevm_engine_common::db_keys::DbKeyCache;
use fhevm_engine_common::tfhe_ops::current_ciphertext_version;
use fhevm_engine_common::types::SupportedFheCiphertexts;
use fhevm_engine_common::utils::DatabaseURL;
use host_listener::contracts::TfheContract::{self, TfheContractEvents};
use host_listener::database::tfhe_event_propagate::{
    operand_boundary_mask_from_minted, uniform_allowed_outputs, Database as ListenerDatabase,
    Handle, LogTfhe, Transaction,
};
use sqlx::types::time::PrimitiveDateTime;
use sqlx::PgPool;

const CHAIN_ID: u64 = 12345; // matches host_chains row seeded by test-harness
const FHE_UINT64: u8 = 5;

fn handle(chain_id: u64, fhe_type: u8) -> Handle {
    // Same layout the executor uses: random prefix, chain id in bytes 22..30,
    // type in byte 30, handle version in byte 31.
    let mut h = [0u8; 32];
    h[..22].copy_from_slice(&rand::random::<[u8; 22]>());
    h[22..30].copy_from_slice(&chain_id.to_be_bytes());
    h[30] = fhe_type;
    h[31] = 0;
    Handle::from(h)
}

async fn insert_event(
    db: &ListenerDatabase,
    tx: &mut Transaction<'_>,
    tx_id: Handle,
    event: TfheContractEvents,
    allowed: bool,
    log_index: u64,
) -> Result<()> {
    let inner = Log::<TfheContractEvents> { address: Address::ZERO, data: event };
    let minted: std::collections::HashSet<Vec<u8>> = sqlx::query_scalar::<_, Vec<u8>>(
        "SELECT output_handle FROM computations WHERE transaction_id = $1",
    )
    .bind(tx_id.to_vec())
    .fetch_all(&mut **tx)
    .await?
    .into_iter()
    .collect();
    let mask = operand_boundary_mask_from_minted(&inner.data, |h| minted.contains(h.as_slice()))
        .map_err(|e| anyhow!("{e}"))?;
    let log = LogTfhe {
        allowed_outputs: uniform_allowed_outputs(&inner, allowed),
        event: inner,
        transaction_hash: Some(tx_id),
        block_number: 0,
        block_hash: Handle::ZERO,
        block_timestamp: PrimitiveDateTime::MAX,
        dependence_chain: tx_id,
        tx_depth_size: 0,
        log_index: Some(log_index),
        operand_boundary_mask: Some(mask),
        is_executor_minted: true,
    };
    db.insert_tfhe_event(tx, &log).await?;
    Ok(())
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
    let url = std::env::var("DATABASE_URL").context("DATABASE_URL is not set")?;
    let (x, y) = (
        std::env::var("X").ok().and_then(|v| v.parse::<u64>().ok()).unwrap_or(3),
        std::env::var("Y").ok().and_then(|v| v.parse::<u64>().ok()).unwrap_or(5),
    );
    let pool = PgPool::connect(&url).await.context("connect")?;
    let db_url: DatabaseURL = url.clone().into();
    let db = ListenerDatabase::new(&db_url, ChainId::try_from(CHAIN_ID)?, 16).await?;

    let tx_id = handle(CHAIN_ID, 0);
    let a = handle(CHAIN_ID, FHE_UINT64);
    let b = handle(CHAIN_ID, FHE_UINT64);
    let c = handle(CHAIN_ID, FHE_UINT64);
    println!("tx    {}", hex::encode(tx_id));
    println!("a = {x}  -> {}", hex::encode(a));
    println!("b = {y}  -> {}", hex::encode(b));
    println!("c = a+b -> {}", hex::encode(c));

    // 1. write the three events like host-listener would for one transaction
    let mut tx = db
        .new_transaction()
        .await?
        .ok_or_else(|| anyhow!("stack paused"))?;
    let caller = Address::ZERO;
    insert_event(&db, &mut tx, tx_id,
        TfheContractEvents::TrivialEncrypt(TfheContract::TrivialEncrypt {
            caller, pt: U256::from(x), toType: FHE_UINT64, result: a }), false, 0).await?;
    insert_event(&db, &mut tx, tx_id,
        TfheContractEvents::TrivialEncrypt(TfheContract::TrivialEncrypt {
            caller, pt: U256::from(y), toType: FHE_UINT64, result: b }), false, 1).await?;
    insert_event(&db, &mut tx, tx_id,
        TfheContractEvents::FheAdd(TfheContract::FheAdd {
            caller, lhs: a, rhs: b, scalarByte: FixedBytes([0u8]), result: c }), true, 2).await?;
    // c is "allowed": host-listener would also queue it for SnS + upload
    db.insert_pbs_computations(&mut tx, &[c.to_vec()], Some(tx_id.to_vec()), 0).await?;
    tx.commit().await?;

    // 2. the dependence-chain row host-listener writes at block end
    sqlx::query(
        "INSERT INTO dependence_chain (dependence_chain_id, status, dependency_count, dependents,
                                       block_height, block_timestamp, schedule_priority)
         VALUES ($1, 'updated', 0, '{}'::bytea[], 0, NOW(), 0)
         ON CONFLICT (dependence_chain_id) DO NOTHING",
    )
    .bind(tx_id.to_vec())
    .execute(&pool)
    .await?;
    sqlx::query("SELECT pg_notify('work_available', '')").execute(&pool).await?;
    println!("events written, waiting for tfhe-worker");

    // 3. wait for the result ciphertext
    let version = current_ciphertext_version();
    let t0 = Instant::now();
    let (ct, ct_type): (Vec<u8>, i16) = wait_for("ciphertext c", Duration::from_secs(180), || {
        let pool = pool.clone();
        let c = c.to_vec();
        async move {
            Ok(sqlx::query_as::<_, (Vec<u8>, i16)>(
                "SELECT ciphertext, ciphertext_type FROM ciphertexts WHERE handle = $1 AND ciphertext_version = $2",
            )
            .bind(c)
            .bind(version)
            .fetch_optional(&pool)
            .await?)
        }
    })
    .await?;
    println!("c computed after {:.1}s ({} bytes, type {ct_type})", t0.elapsed().as_secs_f32(), ct.len());

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
    println!("decrypt(c) = {value}");
    if value != (x + y).to_string() {
        return Err(anyhow!("expected {}, got {value}", x + y));
    }

    // 5. optional: the rest of the pipeline (SnS + upload + digest)
    let t1 = Instant::now();
    let digest = wait_for("ciphertext_digest for c", Duration::from_secs(240), || {
        let pool = pool.clone();
        let c = c.to_vec();
        async move {
            Ok(sqlx::query_as::<_, (Option<Vec<u8>>, Option<Vec<u8>>)>(
                "SELECT ciphertext, ciphertext128 FROM ciphertext_digest WHERE handle = $1",
            )
            .bind(c)
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
    println!("OK: {x} + {y} = {value}");
    Ok(())
}
