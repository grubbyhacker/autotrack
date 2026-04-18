PYTHON ?= python3
TEST_CLI := tools/autotrack_test_cli.py

.PHONY: test test-list \
	phase1 phase2 phase3 phase4 phase4_pads phase4_rampjump phase4_crestdip phase4_chicane \
	phase4_5 phase4_5_geometry phase4_5_lap phase4_5_speed \
	phase5 phase5_unit phase6 phase6_unit phase6_integration phase7 phase7_unit phase7_integration \
	phase8 phase8_unit phase8_integration \
	phase9 phase9_unit phase9_integration \
	phase10 phase10_unit phase10_integration \
	phase11 phase11_unit

test:
	@test -n "$(TEST)" || (echo "Usage: make test TEST=phase6_integration" && exit 2)
	@$(PYTHON) $(TEST_CLI) run "$(TEST)"

test-list:
	@$(PYTHON) $(TEST_CLI) list

phase1 phase2 phase3 phase4 phase4_pads phase4_rampjump phase4_crestdip phase4_chicane phase4_5 phase4_5_geometry phase4_5_lap phase4_5_speed phase5 phase5_unit phase6 phase6_unit phase6_integration phase7 phase7_unit phase7_integration phase8 phase8_unit phase8_integration phase9 phase9_unit phase9_integration phase10 phase10_unit phase10_integration phase11 phase11_unit:
	@$(PYTHON) $(TEST_CLI) run "$@"
