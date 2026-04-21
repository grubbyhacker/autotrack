-- Constants.luau
-- Tuning constants and fixed thresholds shared across AutoTrack modules.

local Constants = {}
Constants.BUILD_STAMP = "fc4749e-local"

-- Track generator defaults
Constants.TRACK_ROWS = 2
Constants.TRACK_COLS = 5

-- Sector geometry (studs)
Constants.STRAIGHT_LENGTH = 120     -- fixed uniform length for all straight sectors
Constants.TRACK_WIDTH = 16
Constants.TRACK_THICKNESS = 2

-- Corner geometry
Constants.CORNER_RADIUS = 20        -- centerline radius for 90-degree corners
Constants.CORNER_ARC_SAMPLES = 13   -- waypoints per corner arc (includes endpoints); denser arc reduces sector handoff wander
Constants.CORNER_SPEED_FACTOR = 0.20      -- slower fixed-corner target; baseline laps must stay planted, not theatrically loose
Constants.CORNER_ENTRY_SHOULDER_FRACTION = 0.40 -- brake earlier into corners so the straight→corner handoff is settled before apex
Constants.CORNER_EXIT_SHOULDER_FRACTION = 0.22  -- hold corner speed longer and delay re-accel until later in corner exit
Constants.CORNER_CORNER_SHOULDER_LENGTH = 10 -- compact shoulder on fixed corner-to-corner joins
Constants.CORNER_EDITABLE_SHOULDER_LENGTH = 60 -- fixed corners own at least half a straight before handing off to an editable sector
Constants.CORNER_SHOULDER_SAMPLE_SPACING = 12 -- dense fixed guidance along long corner-owned recovery straights
Constants.CORNER_CURVE_HANDLE_LENGTH = 8   -- bezier handle length between the two corner shoulders
Constants.CORNER_ENTRY_BRAKE_RATE = 340    -- brake assertively on the fixed entry shoulder so corner approach is deterministic
Constants.CORNER_EXIT_ACCEL_RATE = 180     -- accelerate harder on the editable-side exit shoulder so handoffs do not feel sluggish
Constants.CORNER_EXIT_ACCEL_ALIGN_DOT = 0.992 -- do not accelerate out of a corner until the nose is almost fully aligned with the straight
Constants.POST_CORNER_ACCEL_STRAIGHT_WINDOW = 0.15 -- keep the no-accel handoff alive briefly into the following straight if rotation is still settling
Constants.CORNER_WAYPOINT_LOOKAHEAD = 1    -- mild path anticipation in corners; keeps the nose rotating into the turn
Constants.CORNER_ORIENTATION_LOOKAHEAD = 2 -- stronger heading anticipation than path-follow lookahead
Constants.CORNER_ORIENTATION_BLEND = 0.45  -- blend current segment with anticipated heading in corners
Constants.STRAIGHT_GUIDE_SPACING = 20      -- add intermediate straight waypoints so entry recovery has nearby guidance, not just a distant midpoint
Constants.MECHANIC_ENTRY_SPEED_FACTOR = 0.62 -- default cap for non-boost mechanic lead-ins before the authored feature begins
Constants.POST_CORNER_MECHANIC_ENTRY_SPEED_FACTOR = 0.34 -- generic post-corner cap for sectors 2/7 so mechanics inherit a stabilized entry state
Constants.RAMPJUMP_ENTRY_SPEED_FACTOR = 0.34 -- plain ramps should enter slower so sector-3 defaults stay low-risk and recoverable
Constants.POST_CORNER_RAMPJUMP_ENTRY_SPEED_FACTOR = 0.22 -- post-corner ramps need a very calm approach to avoid late-landing chaos
Constants.RAMPJUMP_ENTRY_BLEND_POWER = 2.4 -- hold the lower RampJump lead-in cap longer so speed does not spike right before takeoff
Constants.CRESTDIP_ENTRY_SPEED_FACTOR = 0.48 -- CrestDip lead-ins need a calmer pre-feature settle than RampJump to avoid flat-entry tumbles
Constants.POST_CORNER_CRESTDIP_ENTRY_SPEED_FACTOR = 0.30 -- sector-2/7 crest lead-ins need extra recovery after fixed-corner exits
Constants.POST_CORNER_ENTRY_BLEND_POWER = 2.2 -- keep the post-corner recovery cap active much longer before blending back to full speed
Constants.CRESTDIP_ENTRY_BLEND_POWER = 1.8 -- keep the CrestDip recovery cap in place longer, then blend back up closer to the feature

-- Physics / boost pads
Constants.BASELINE_SPEED = 100
Constants.PAD_BOOST_FORCE = 6000
Constants.PAD_BRAKE_FORCE = -4000

-- Car dimensions (studs)
Constants.CAR_WIDTH = 4
Constants.CAR_HEIGHT = 2
Constants.CAR_LENGTH = 8

-- Waypoint follower
Constants.WAYPOINT_LOOKAHEAD = 1
Constants.ORIENTATION_LOOKAHEAD = 2
Constants.ORIENTATION_BLEND = 0.7
Constants.WAYPOINT_STALL_TIME_THRESHOLD = 3.0

-- Verifier car
Constants.CAR_TARGET_SPEED = 100    -- studs/s baseline forward speed (walked back from 130 for obstacle reliability)
Constants.CAR_ROOT_DENSITY = 19.5   -- 4x2x8 root at density 19.5 ≈ 1248 mass-units; closer to rally-car inertia for stability tests
Constants.CAR_ACCEL_RATE = 90       -- studs/s^2 rise toward straight-line target speed
Constants.CAR_BRAKE_RATE = 280      -- stronger decel for fixed-corner containment; baseline should never drift fully off track
Constants.CAR_SUSPENSION_VERTICAL_DAMPING = 85 -- grounded damping toward zero vertical velocity to soften grade/landing response
Constants.CAR_SUSPENSION_ANGULAR_DAMPING = 18  -- grounded damping of pitch/roll angular velocity
Constants.CAR_STRAIGHT_YAW_DAMPING = 0         -- default off; enable live via workspace attrs once tuned
Constants.CAR_CORNER_YAW_DAMPING = 0           -- default off; corner steering should not be constrained until tuned
Constants.CAR_AIRBORNE_YAW_DAMPING = 0         -- default off; airborne yaw resistance can be live-tuned without perturbing baseline
Constants.CAR_LANDING_MIN_DOWN_SPEED = 12      -- only treat touchdown as a landing event above this downward speed
Constants.CAR_LANDING_VERTICAL_MULTIPLIER = 0.35 -- immediate touchdown damping on vertical speed
Constants.CAR_LANDING_ANGULAR_MULTIPLIER = 0.45 -- immediate touchdown damping on pitch/roll angular velocity
Constants.RAMPJUMP_LANDING_MIN_DOWN_SPEED = 8
Constants.RAMPJUMP_LANDING_VERTICAL_MULTIPLIER = 0.18
Constants.RAMPJUMP_LANDING_ANGULAR_MULTIPLIER = 0.25
Constants.CAR_MAX_LATERAL_CORRECTION = 20   -- studs/s lateral impulse cap
Constants.CAR_MAX_ORIENT_CORRECTION = 10    -- deg/s heading correction cap
Constants.CAR_ORIENTATION_RESPONSIVENESS = 12
Constants.CAR_ORIENTATION_MAX_TORQUE = 25000
Constants.CAR_STRAIGHT_ORIENTATION_RESPONSIVENESS = 18 -- straights should resist yaw drift more aggressively than corners
Constants.CAR_CORNER_ORIENTATION_RESPONSIVENESS = 12   -- corners retain the older responsiveness so turn-in stays natural
Constants.CAR_STRAIGHT_ORIENTATION_MAX_TORQUE = 35000  -- extra straight-line heading authority helps post-corner stabilization
Constants.CAR_CORNER_ORIENTATION_MAX_TORQUE = 25000    -- preserve established corner behavior by default
Constants.CAR_AIRBORNE_ORIENTATION_MAX_TORQUE = 7000
Constants.STRAIGHT_ORIENTATION_PIN_ENABLED = true      -- for demo reliability, non-corner sectors pin yaw/roll strongly toward track-forward
Constants.STRAIGHT_PIN_YAW_DAMPING = 40               -- aggressively kill yaw rotation on straights
Constants.STRAIGHT_PIN_ROLL_DAMPING = 40              -- aggressively kill roll rotation on straights
Constants.STRAIGHT_PIN_MAX_YAW_RATE = 0.75            -- cap residual yaw rate on straights
Constants.STRAIGHT_PIN_MAX_ROLL_RATE = 0.75           -- cap residual roll rate on straights
Constants.STRAIGHT_PIN_ORIENTATION_RESPONSIVENESS = 30
Constants.STRAIGHT_PIN_ORIENTATION_MAX_TORQUE = 70000
Constants.RAMPJUMP_AIRBORNE_HEADING_FREEZE_ENABLED = true -- once airborne on a ramp, hold takeoff heading instead of steering toward future waypoints
Constants.RAMPJUMP_AIRBORNE_YAW_DAMPING = 12            -- resist spin/yaw while airborne on a RampJump
Constants.RAMPJUMP_AIRBORNE_ORIENTATION_MAX_TORQUE = 3500 -- lower airborne torque in ramp context so the verifier does not twist itself mid-flight
Constants.TARGET_ENTRY_STATE_NORMALIZE_ENABLED = true   -- optional deterministic assist: normalize state at target-sector entry
Constants.TARGET_ENTRY_NORMALIZED_SPEED_FACTOR = 0.34   -- normalized entry speed as a fraction of CAR_TARGET_SPEED
Constants.TARGET_ENTRY_NORMALIZED_SPEED_FACTOR_RAMPJUMP = 0.22
Constants.TARGET_ENTRY_NORMALIZED_SPEED_FACTOR_CRESTDIP = 0.28
Constants.TARGET_ENTRY_NORMALIZED_SPEED_FACTOR_CHICANE = 0.32
Constants.TARGET_ENTRY_ORIENTATION_SNAP_ENABLED = true  -- snap yaw upright toward local path direction when normalizing entry state
Constants.TARGET_SECTOR_STABILITY_ASSIST_ENABLED = true -- clamp extreme angular/vertical spikes inside target sector to reduce physics-only flake
Constants.TARGET_SECTOR_STABILITY_MAX_ANGULAR_SPEED = 16
Constants.TARGET_SECTOR_STABILITY_MAX_VERTICAL_SPEED = 60
Constants.RAMPJUMP_TARGET_SECTOR_STABILITY_MAX_ANGULAR_SPEED = 7
Constants.RAMPJUMP_TARGET_SECTOR_STABILITY_MAX_VERTICAL_SPEED = 28
Constants.RAMPJUMP_RECOVERY_TIME = 1.25 -- keep post-landing stabilization alive briefly after target-sector exit
Constants.RAMPJUMP_RECOVERY_SPEED_FACTOR = 0.24 -- cap recovery-speed in the first downstream straight after a ramp landing
Constants.RAMPJUMP_RECOVERY_MAX_ANGULAR_SPEED = 4.5
Constants.RAMPJUMP_RECOVERY_MAX_VERTICAL_SPEED = 18

-- Lap timing
Constants.LAP_TIMEOUT = 60          -- seconds before a run is declared system_failure (phase 14: more headroom at extreme difficulty)
Constants.STALL_SPEED_THRESHOLD = 4
Constants.STALL_TIME_THRESHOLD = 1.5
Constants.NO_PROGRESS_DISTANCE_THRESHOLD = 2
Constants.NO_PROGRESS_TIME_THRESHOLD = 1.25
Constants.CRASH_ANGULAR_SPEED_THRESHOLD = 1.5
Constants.SPIN_ANGULAR_SPEED_THRESHOLD = 3.0
Constants.SPIN_FAILURE_ANGLE_RAD = math.pi
Constants.SPIN_RESET_ANGULAR_SPEED_THRESHOLD = 1.0
Constants.TUMBLE_ANGULAR_SPEED_THRESHOLD = 4
Constants.TUMBLE_TIME_THRESHOLD = 0.1
Constants.TUMBLE_UP_DOT_THRESHOLD = 0.92
Constants.OVERTURN_UP_DOT_THRESHOLD = -0.25
Constants.OVERTURN_TIME_THRESHOLD = 0.75
Constants.AIRBORNE_OVERTURN_TIME_THRESHOLD = 0.3
Constants.INVALID_ATTITUDE_UP_DOT_THRESHOLD = 0.35
Constants.INVALID_ATTITUDE_TIME_THRESHOLD = 0.4
Constants.BACKWARD_FACING_DOT_THRESHOLD = -0.2
Constants.BACKWARD_FACING_TIME_THRESHOLD = 0.5
Constants.OFF_TRACK_FAILURE_DISTANCE = Constants.TRACK_WIDTH * 1.0 -- centerline distance at which the run is considered visibly off the road
Constants.FRONT_BODY_CONTAINMENT_DISTANCE = Constants.TRACK_WIDTH * 0.95 -- front-of-car footprint should stay inside this to avoid nose-out “successful” laps

-- CI loop
Constants.MAX_REPAIR_ATTEMPTS = 7
Constants.EXTRA_REPAIR_ATTEMPTS_AFTER_HALF_PROGRESS = 2

-- Pad effect magnitudes (fixed, not agent-tunable)
Constants.BOOST_SPEED_DELTA = 10    -- legacy medium-boost alias
Constants.BRAKE_SPEED_DELTA = -10   -- legacy medium-brake alias

-- RampJump integrity thresholds
Constants.RAMPJUMP_MIN_GAP = 2              -- studs
Constants.RAMPJUMP_MIN_AIR_DISTANCE = 2.0   -- retained as telemetry guidance only; Phase 16 no longer requires dramatic airtime for a playable ramp
Constants.RAMPJUMP_MIN_VERTICAL_DISPLACEMENT = 1.5 -- low-risk ramps should still visibly lift the car above the flat road
Constants.RAMPJUMP_REACQUIRE_MAX = 12       -- studs after landing (phase 14: tightened from 20)

-- Chicane integrity thresholds
Constants.CHICANE_MIN_LATERAL_DISPLACEMENT = 4  -- studs
Constants.CHICANE_MIN_ALTERNATIONS = 2
Constants.CHICANE_MIN_CURVATURE = 0.05          -- 1/studs
Constants.CHICANE_LATERAL_BAND_THRESHOLD = 2    -- studs; local X threshold for left/center/right band transitions
Constants.CHICANE_SCORE_ALT_FULL = 3            -- band changes mapping to full alternation credit
Constants.CHICANE_SPEED_RETENTION_FLOOR = 0.65  -- chicane score falls off below this target min-speed ratio
Constants.CHICANE_INGRESS_BRAKE_PENALTY = 2.0   -- score penalty for brake-heavy "safe" chicanes
Constants.CRESTDIP_EGRESS_BRAKE_PENALTY = 2.5   -- score penalty for exit-brake crests; they sabotage downstream setup

-- CrestDip integrity thresholds
Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT = 3  -- studs
Constants.CRESTDIP_MIN_CURVATURE = 0.005          -- |h|/L^2, 1/studs; relaxed for the smoother sampled cosine crest
Constants.CRESTDIP_MAX_AIRTIME_DISTANCE = 30      -- studs; largest allowed airborne segment after liftoff
Constants.CRESTDIP_APEX_PROGRESS_RADIUS = 0.12    -- progress window around sector midpoint treated as the crest top
Constants.CRESTDIP_APEX_MIN_SPEED = 20            -- studs/s minimum speed across the crest top for resilience

-- Phase 11: ChallengeScore weights and budget
-- See plans/phase11.md §3, §10 for the formula and motivation.
Constants.CHALLENGE_BUDGET_RATIO   = 0.50   -- allowed lap-time slowdown vs clean baseline
Constants.CHALLENGE_UP_ROUNDS      = 3      -- score-escalation rounds per job
Constants.SCORE_W_AIR              = 1.0
Constants.SCORE_W_LATERAL          = 1.0
Constants.SCORE_W_NEAR_MISS        = 1.5
Constants.SCORE_W_TIME             = 0.25
Constants.NEAR_MISS_ZERO_AT_MARGIN = 0.75   -- occupancy below this → near-miss component is 0
Constants.LATERAL_G_FULL_SCORE     = 60     -- studs/s² mapping to 10 points
Constants.HANG_TIME_FULL_SCORE     = 0.75   -- seconds mapping to 10 points
Constants.MIN_ESCALATION_DELTA     = 0.25   -- required score improvement for a challenge-up to supersede
Constants.MAXIMIZER_MIN_RETAINED_SECTORS = 2 -- do not evict below this many scored demo sectors

-- UI pacing delays (seconds)
Constants.UI_PHASE_DELAY = 0.75
Constants.UI_FAILURE_DWELL = 1.25
Constants.UI_SUCCESS_DWELL = 2.0

-- Endurance / Hotfix Mode (phase 14)
Constants.ENDURANCE_ATTEMPT_BUDGET = 12         -- total orchestrator sector placements
Constants.ENDURANCE_LAP_TIME_BUDGET_RATIO = 0.40 -- max allowed slowdown fraction vs baseline
Constants.HOTFIX_MAX_ATTEMPTS = 5               -- repair attempts before hotfix declares failure

-- Camera tuning
Constants.CAMERA_CHASE_HEIGHT = 20
Constants.CAMERA_CHASE_DISTANCE = 45
Constants.CAMERA_SIDE_OFFSET = 60
Constants.CAMERA_SIDE_HEIGHT = 30
Constants.CAMERA_SIDE_BACK_OFFSET = 6
Constants.CAMERA_SIDE_LOOK_AHEAD = 6
Constants.CAMERA_PREROLL_BACK_DISTANCE = 84
Constants.CAMERA_PREROLL_START_PROGRESS = 0.2
Constants.CAMERA_PREROLL_FULL_PROGRESS = 0.85
Constants.CAMERA_PREROLL_CURVE_POWER = 1.35
Constants.CAMERA_FOCUS_HEIGHT = 2.5
Constants.CAMERA_FOCUS_LEAD = 2
Constants.CAMERA_ALPHA_ENTER_SHARPNESS = 0.45
Constants.CAMERA_ALPHA_EXIT_SHARPNESS = 0.9
Constants.CAMERA_OBSTACLE_PREROLL_SECTORS = 1

return Constants
