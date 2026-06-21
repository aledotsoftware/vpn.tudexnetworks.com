1. *Fix CI validation script*
   - Modify `scripts/test-infra.sh` to use `sudo mkdir -p /etc/headscale/errors` and `sudo cp` for mocking the HAProxy environment instead of using `/tmp` or sedding the configuration file, as HAProxy requires absolute paths to exist for `haproxy -c`.
2. *Refine HAProxy hardening*
   - Add additional scanner signatures (`wget`, `libwww-perl`, `curl`) to the `is_scanner` regex in `config/haproxy.cfg`.
3. *Enhance database schema and frontend UI*
   - Add a `CHECK (config_key <> '')` constraint to `cluster_config` in `database/schema.sql`.
   - Add `hitRadius: 10` to `config/dashboard.html` to improve Chart.js interactivity.
4. *Run relevant tests*
   - Run `./scripts/test-infra.sh` to verify configuration changes.
5. *Pre Commit Steps*
   - Complete pre-commit steps to ensure proper testing, verification, review, and reflection are done.
6. *Submit the change.*
   - Submit the task with a descriptive branch and commit message.
