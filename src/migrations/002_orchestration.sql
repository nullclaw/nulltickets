-- Add workflow execution tracking
ALTER TABLE tasks ADD COLUMN run_id TEXT;
ALTER TABLE tasks ADD COLUMN workflow_state_json TEXT;

-- Drop quality gates (moved to workflow logic in NullBoiler)
DROP TABLE IF EXISTS gate_results;
