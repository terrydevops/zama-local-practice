-- Pipeline counters at a glance.
--   psql ... -f watch.sql      or   watch.sh loop

\pset footer off
\echo '== verify_proofs'
SELECT
  count(*) FILTER (WHERE verified IS NULL)  AS pending,
  count(*) FILTER (WHERE verified = true)   AS verified,
  count(*) FILTER (WHERE verified = false)  AS rejected
FROM verify_proofs;

\echo '== computations'
SELECT
  count(*) FILTER (WHERE NOT is_completed AND NOT is_error) AS todo,
  count(*) FILTER (WHERE is_completed)                      AS done,
  count(*) FILTER (WHERE is_error)                          AS error
FROM computations;

\echo '== dependence_chain'
SELECT status, count(*) FROM dependence_chain GROUP BY status ORDER BY status;

\echo '== ciphertexts / ciphertexts128'
SELECT
  (SELECT count(*) FROM ciphertexts)                          AS ct64,
  (SELECT count(*) FROM ciphertexts WHERE is_input)           AS ct64_inputs,
  (SELECT count(*) FROM ciphertexts128)                       AS ct128;

\echo '== pbs_computations'
SELECT
  count(*) FILTER (WHERE NOT is_completed) AS todo,
  count(*) FILTER (WHERE is_completed)     AS done
FROM pbs_computations;

\echo '== ciphertext_digest'
SELECT
  count(*) FILTER (WHERE NOT txn_is_sent) AS to_send,
  count(*) FILTER (WHERE txn_is_sent)     AS sent,
  count(*) FILTER (WHERE ciphertext IS NULL OR ciphertext128 IS NULL) AS incomplete
FROM ciphertext_digest;

\echo '== keys / host_chains'
SELECT (SELECT count(*) FROM keys) AS keys, (SELECT count(*) FROM crs) AS crs,
       (SELECT string_agg(chain_id::text || ':' || name, ', ') FROM host_chains) AS host_chains;
