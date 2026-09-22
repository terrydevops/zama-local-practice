-- The stress generator inserts computations but not the dependence_chain rows that
-- host-listener would write at block end, so tfhe-worker never picks the work up.
INSERT INTO dependence_chain (dependence_chain_id, status, dependency_count, dependents,
                              block_height, block_timestamp, schedule_priority)
SELECT DISTINCT dependence_chain_id, 'updated', 0, '{}'::bytea[], 1, NOW(), 0
FROM computations
WHERE NOT is_completed AND dependence_chain_id IS NOT NULL
ON CONFLICT (dependence_chain_id) DO NOTHING;
SELECT pg_notify('work_available', '');
