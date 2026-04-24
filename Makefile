PYTHON ?= python3
TEST_CLI := tools/autotrack_test_cli.py
ROKIT_BIN ?= $(HOME)/.rokit/bin
ROJO := $(ROKIT_BIN)/rojo
STYLUA := $(ROKIT_BIN)/stylua
LUAU_LSP := $(ROKIT_BIN)/luau-lsp
SELENE := $(ROKIT_BIN)/selene
HYGIENE_SOURCE_FILES := $(shell find src studio -type f \( -name '*.luau' -o -name '*.server.luau' -o -name '*.client.luau' \) 2>/dev/null | LC_ALL=C sort)
ROJO_PROJECT := default.project.json
TYPECHECK_SOURCEMAP := sourcemap.json
ROBLOX_GLOBAL_TYPES := tools/luau/globalTypes.None.d.luau
TYPECHECK_GREEN_FILES := \
	src/common/Constants.luau \
	src/common/LLMConfig.luau \
	src/common/LaunchOutlier.luau \
	src/common/LevelMappings.luau \
	src/common/PadValueUtils.luau \
	src/common/RuntimeTuning.luau \
	src/common/Types.luau \
	src/agent/ActionValidator.luau \
	src/client/TrackCamera.client.luau

.PHONY: test test-list \
	test-contracts \
	fmt fmt-check typecheck typecheck-report lint hygiene \
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
	phase22 phase22_command_surface phase22_endurance_entry phase23 phase24 phase26 phase27 phase30 \
	refactor_fast mechanics_regression llm_trace_export export-llm-trace endurance-trace inspect-llm-trace

test:
	@test -n "$(TEST)" || (echo "Usage: make test TEST=phase6_integration" && exit 2)
	@$(PYTHON) $(TEST_CLI) run "$(TEST)"

test-list:
	@$(PYTHON) $(TEST_CLI) list

test-contracts:
	@$(PYTHON) tools/check_test_contract.py

fmt:
	@$(STYLUA) $(HYGIENE_SOURCE_FILES)

fmt-check:
	@$(STYLUA) --check $(HYGIENE_SOURCE_FILES)

typecheck:
	@$(ROJO) sourcemap $(ROJO_PROJECT) --output $(TYPECHECK_SOURCEMAP) --absolute >/dev/null
	@$(LUAU_LSP) analyze --platform=roblox --definitions @roblox=$(ROBLOX_GLOBAL_TYPES) --sourcemap $(TYPECHECK_SOURCEMAP) $(TYPECHECK_GREEN_FILES)

typecheck-report:
	@$(ROJO) sourcemap $(ROJO_PROJECT) --output $(TYPECHECK_SOURCEMAP) --absolute >/dev/null
	@set +e; \
	$(LUAU_LSP) analyze --platform=roblox --definitions @roblox=$(ROBLOX_GLOBAL_TYPES) --sourcemap $(TYPECHECK_SOURCEMAP) $(HYGIENE_SOURCE_FILES); \
	rc=$$?; \
	echo "[typecheck-report] luau-lsp exit=$$rc"; \
	exit 0

lint:
	@$(SELENE) --config selene.toml $(HYGIENE_SOURCE_FILES)

hygiene: fmt-check typecheck lint

boot_smoke phase1 phase2 phase3 phase4 phase4_pads phase4_rampjump phase4_crestdip phase4_chicane phase4_chicane_capture phase4_5 phase4_5_geometry phase4_5_lap phase4_5_speed phase5 phase5_unit phase6 phase6_unit phase6_integration phase9 phase9_unit phase9_integration phase11 phase11_unit phase11_integration phase13 phase13_unit phase13_integration phase14 phase14_unit phase14_integration phase14_crestdip_pair phase14_crestdip_search phase14_sector2_debug phase14_5 phase15 phase16 phase18 phase19 phase20 phase21 phase21_unit phase21_integration phase21_experiment phase21_rampjump_torture phase22 phase22_command_surface phase22_endurance_entry phase23 phase24 phase26 phase27 phase30 refactor_fast mechanics_regression llm_trace_export:
	@$(PYTHON) $(TEST_CLI) run "$@"

export-llm-trace:
	@$(PYTHON) $(TEST_CLI) export-llm-trace

endurance-trace:
	@$(PYTHON) $(TEST_CLI) endurance-trace --model "$(MODEL)" --duration "$(or $(DURATION),60)" $(if $(OUT),--out "$(OUT)",)

inspect-llm-trace:
	@test -n "$(TRACE)" || (echo "Usage: make inspect-llm-trace TRACE=traces/endurance-gemma.json [RAW=1]" && exit 2)
	@$(PYTHON) $(TEST_CLI) inspect-llm-trace "$(TRACE)" $(if $(RAW),--show-raw,)
