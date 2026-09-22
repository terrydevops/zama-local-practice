//! Local-study helper (not part of the upstream repo): prepare a plain
//! Postgres as a coprocessor database the way the test harness does.
//!
//!   1. run all migrations from ../db-migration/migrations
//!   2. bootstrap the `versioning` row
//!   3. import the test FHE keys from ../fhevm-keys (xof-keyset, xof-cks, pp)
//!      into `keys` / `crs`, and add host chain 12345 to `host_chains`
//!
//! Run from the `test-harness` directory (paths are relative to it):
//!
//!   ./seed.sh   (see seed.sh; runs from the test-harness dir so ../fhevm-keys resolves)


use sqlx::postgres::PgPoolOptions;
use test_harness::db_utils::setup_test_key;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let db_url = std::env::var("DATABASE_URL").map_err(|_| "DATABASE_URL is not set")?;
    let with_sns_pk = std::env::var("SEED_WITH_SNS_PK")
        .map(|v| v == "true" || v == "1")
        .unwrap_or(true);

    let pool = PgPoolOptions::new().max_connections(5).connect(&db_url).await?;

    // Same bootstrap marker the harness creates before migrating.
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS public._fhevm_versioning_bootstrap (
            singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )",
    )
    .execute(&pool)
    .await?;
    sqlx::query(
        "INSERT INTO public._fhevm_versioning_bootstrap (singleton) VALUES (TRUE)
         ON CONFLICT DO NOTHING",
    )
    .execute(&pool)
    .await?;

    println!("running migrations…");
    sqlx::migrate!("../../../zama-ai-repos/fhevm/coprocessor/fhevm-engine/db-migration/migrations").run(&pool).await?;

    println!("bootstrapping versioning…");
    fhevm_engine_common::bootstrap_versioning::bootstrap_versioning(&pool).await?;

    let already: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM keys")
        .fetch_one(&pool)
        .await?;
    if already > 0 {
        println!("keys table already has {already} row(s); skipping key import");
    } else {
        println!("importing test keys (with_sns_pk={with_sns_pk})…");
        setup_test_key(&pool, with_sns_pk).await?;
    }

    let (keys, crs, chains): (i64, i64, i64) = (
        sqlx::query_scalar("SELECT COUNT(*) FROM keys").fetch_one(&pool).await?,
        sqlx::query_scalar("SELECT COUNT(*) FROM crs").fetch_one(&pool).await?,
        sqlx::query_scalar("SELECT COUNT(*) FROM host_chains").fetch_one(&pool).await?,
    );
    println!("done: keys={keys} crs={crs} host_chains={chains}");
    Ok(())
}
