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

-- Physics / boost pads
Constants.BASELINE_SPEED = 40
Constants.PAD_BOOST_FORCE = 6000
Constants.PAD_BRAKE_FORCE = -4000

-- Car dimensions (studs)
Constants.CAR_WIDTH = 4
Constants.CAR_HEIGHT = 2
Constants.CAR_LENGTH = 8

-- Waypoint follower
Constants.WAYPOINT_LOOKAHEAD = 1

-- Verifier car
Constants.CAR_TARGET_SPEED = 40     -- studs/s baseline forward speed
Constants.CAR_MAX_LATERAL_CORRECTION = 20   -- studs/s lateral impulse cap
Constants.CAR_MAX_ORIENT_CORRECTION = 10    -- deg/s heading correction cap

-- Lap timing
Constants.LAP_TIMEOUT = 120         -- seconds before a run is declared system_failure
Constants.STALL_SPEED_THRESHOLD = 2
Constants.STALL_TIME_THRESHOLD = 2.5

-- CI loop
Constants.MAX_REPAIR_ATTEMPTS = 5

-- Pad effect magnitudes (fixed, not agent-tunable)
Constants.BOOST_SPEED_DELTA = 15    -- studs/s added
Constants.BRAKE_SPEED_DELTA = -15   -- studs/s removed

-- RampJump integrity thresholds
Constants.RAMPJUMP_MIN_GAP = 2              -- studs
Constants.RAMPJUMP_MIN_AIR_DISTANCE = 5     -- studs
Constants.RAMPJUMP_REACQUIRE_MAX = 20       -- studs after landing

-- Chicane integrity thresholds
Constants.CHICANE_MIN_LATERAL_DISPLACEMENT = 4  -- studs
Constants.CHICANE_MIN_ALTERNATIONS = 2
Constants.CHICANE_MIN_CURVATURE = 0.05          -- 1/studs

-- CrestDip integrity thresholds
Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT = 2  -- studs
Constants.CRESTDIP_MIN_CURVATURE = 0.02           -- 1/studs

-- UI pacing delays (seconds)
Constants.UI_PHASE_DELAY = 0.75
Constants.UI_SUCCESS_DWELL = 2.0

return Constants
