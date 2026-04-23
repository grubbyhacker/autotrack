PYTHON ?= python3
TEST_CLI := tools/autotrack_test_cli.py

.PHONY: test test-list \
	test-contracts \
	boot_smoke \
	phase1 phase2 phase3 phase4 phase4_pads phase4_rampjump phase4_crestdip phase4_chicane phase4_chicane_capture \
	phase4_5 phase4_5_geometry phase4_5_lap phase4_5_speed \
	phase5 phase5_unit phase6 phase6_unit phase6_integration \
	phase9 phase9_unit phase9_integration \
	phase11 phase11_unit phase11_integration \
	phase13 phase13_unit phase13_integration \
	phase14 phase14_unit phase14_integration phase14_crestdip_pair phase14_crestdip_search phase14_sector2_debug \
	phase14_5 phase15 phase16 phase18 phase19 phase20 phase21 phase21_unit phase21_integration phase21_experiment \
	phase21_rampjump_torture \
	phase22 phase22_command_surface phase22_endurance_entry phase23 phase24 phase26 \
	refactor_fast mechanics_regression llm_trace_export export-llm-trace endurance-trace inspect-llm-trace

test:
	@test -n "$(TEST)" || (echo "Usage: make test TEST=phase6_integration" && exit 2)
	@$(PYTHON) $(TEST_CLI) run "$(TEST)"

test-list:
	@$(PYTHON) $(TEST_CLI) list

test-contracts:
	@$(PYTHON) tools/check_test_contract.py

boot_smoke phase1 phase2 phase3 phase4 phase4_pads phase4_rampjump phase4_crestdip phase4_chicane phase4_chicane_capture phase4_5 phase4_5_geometry phase4_5_lap phase4_5_speed phase5 phase5_unit phase6 phase6_unit phase6_integration phase9 phase9_unit phase9_integration phase11 phase11_unit phase11_integration phase13 phase13_unit phase13_integration phase14 phase14_unit phase14_integration phase14_crestdip_pair phase14_crestdip_search phase14_sector2_debug phase14_5 phase15 phase16 phase18 phase19 phase20 phase21 phase21_unit phase21_integration phase21_experiment phase21_rampjump_torture phase22 phase22_command_surface phase22_endurance_entry phase23 phase24 phase26 refactor_fast mechanics_regression llm_trace_export:
	@$(PYTHON) $(TEST_CLI) run "$@"

export-llm-trace:
	@$(PYTHON) $(TEST_CLI) export-llm-trace

endurance-trace:
	@$(PYTHON) $(TEST_CLI) endurance-trace --model "$(MODEL)" --duration "$(or $(DURATION),60)" $(if $(OUT),--out "$(OUT)",)

inspect-llm-trace:
	@test -n "$(TRACE)" || (echo "Usage: make inspect-llm-trace TRACE=traces/endurance-gemma.json [RAW=1]" && exit 2)
	@$(PYTHON) $(TEST_CLI) inspect-llm-trace "$(TRACE)" $(if $(RAW),--show-raw,)
