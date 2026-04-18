-- Constants.luau
-- Tuning constants and fixed thresholds shared across AutoTrack modules.

local Constants = {}

-- Track generator defaults
Constants.TRACK_ROWS = 2
Constants.TRACK_COLS = 5

-- Sector geometry (studs)
Constants.STRAIGHT_LENGTH = 120     -- fixed uniform length for all straight sectors
Constants.TRACK_WIDTH = 16
Constants.TRACK_THICKNESS = 2

-- Corner geometry
Constants.CORNER_RADIUS = 20        -- centerline radius for 90-degree corners
Constants.CORNER_ARC_SAMPLES = 5    -- waypoints per corner arc (includes endpoints)
Constants.CORNER_SPEED_FACTOR = 0.33 -- speed multiplier in corner sectors (80*0.33=26.4 studs/s)

-- Physics / boost pads
Constants.BASELINE_SPEED = 80
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

-- Verifier car
Constants.CAR_TARGET_SPEED = 80     -- studs/s baseline forward speed
Constants.CAR_MAX_LATERAL_CORRECTION = 20   -- studs/s lateral impulse cap
Constants.CAR_MAX_ORIENT_CORRECTION = 10    -- deg/s heading correction cap
Constants.CAR_ORIENTATION_RESPONSIVENESS = 12
Constants.CAR_ORIENTATION_MAX_TORQUE = 25000

-- Lap timing
Constants.LAP_TIMEOUT = 45          -- seconds before a run is declared system_failure
Constants.STALL_SPEED_THRESHOLD = 4
Constants.STALL_TIME_THRESHOLD = 1.5
Constants.NO_PROGRESS_DISTANCE_THRESHOLD = 2
Constants.NO_PROGRESS_TIME_THRESHOLD = 1.25
Constants.CRASH_ANGULAR_SPEED_THRESHOLD = 1.5
Constants.OVERTURN_UP_DOT_THRESHOLD = -0.25
Constants.OVERTURN_TIME_THRESHOLD = 0.75
Constants.AIRBORNE_OVERTURN_TIME_THRESHOLD = 0.3
Constants.INVALID_ATTITUDE_UP_DOT_THRESHOLD = 0.35
Constants.INVALID_ATTITUDE_TIME_THRESHOLD = 0.4
Constants.BACKWARD_FACING_DOT_THRESHOLD = -0.2
Constants.BACKWARD_FACING_TIME_THRESHOLD = 0.5

-- CI loop
Constants.MAX_REPAIR_ATTEMPTS = 7
Constants.EXTRA_REPAIR_ATTEMPTS_AFTER_HALF_PROGRESS = 2

-- Pad effect magnitudes (fixed, not agent-tunable)
Constants.BOOST_SPEED_DELTA = 10    -- legacy medium-boost alias
Constants.BRAKE_SPEED_DELTA = -10   -- legacy medium-brake alias

-- RampJump integrity thresholds
Constants.RAMPJUMP_MIN_GAP = 2              -- studs
Constants.RAMPJUMP_MIN_AIR_DISTANCE = 5     -- studs
Constants.RAMPJUMP_REACQUIRE_MAX = 20       -- studs after landing

-- Chicane integrity thresholds
Constants.CHICANE_MIN_LATERAL_DISPLACEMENT = 4  -- studs
Constants.CHICANE_MIN_ALTERNATIONS = 2
Constants.CHICANE_MIN_CURVATURE = 0.05          -- 1/studs
Constants.CHICANE_LATERAL_BAND_THRESHOLD = 2    -- studs; local X threshold for left/center/right band transitions
Constants.CHICANE_SCORE_ALT_FULL = 3            -- band changes mapping to full alternation credit
Constants.CHICANE_SPEED_RETENTION_FLOOR = 0.65  -- chicane score falls off below this target min-speed ratio
Constants.CHICANE_INGRESS_BRAKE_PENALTY = 2.0   -- score penalty for brake-heavy "safe" chicanes

-- CrestDip integrity thresholds
Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT = 3  -- studs
Constants.CRESTDIP_MIN_CURVATURE = 0.006          -- |h|/L^2, 1/studs
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
