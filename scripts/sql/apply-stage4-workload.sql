INSERT INTO games (
    id, shop_id, played_at, player_nickname, course_name, game_status, updated_at
)
SELECT
    1000001, 1, '2025-12-30 12:00:01.000000', 'stage4-player-1000001',
    'Stage 4 Course', 'COMPLETED', '2026-08-12 00:00:01.000000'
WHERE @elapsed_seconds >= 1
ON DUPLICATE KEY UPDATE id = id;

INSERT INTO rounds (id, game_id, round_number, updated_at)
SELECT 10000010, 1000001, 1, '2026-08-12 00:00:01.000000'
WHERE @elapsed_seconds >= 1
ON DUPLICATE KEY UPDATE id = id;

INSERT INTO round_scores (id, round_id, score, updated_at)
SELECT 100000100, 10000010, 15, '2026-08-12 00:00:01.000000'
WHERE @elapsed_seconds >= 1
ON DUPLICATE KEY UPDATE id = id;

UPDATE games
SET game_status = 'IN_PROGRESS', updated_at = '2026-08-12 00:07:01.000000'
WHERE id = 1000002 AND @elapsed_seconds >= 421;

UPDATE round_scores
SET score = 77, updated_at = '2026-08-12 00:12:01.000000'
WHERE id = 100000300 AND @elapsed_seconds >= 721;

UPDATE games
SET game_status = 'CANCELLED', updated_at = '2026-08-12 00:21:01.000000'
WHERE id BETWEEN 1000004 AND 1000006 AND @elapsed_seconds >= 1261;

UPDATE round_scores
SET score = -12, updated_at = '2026-08-12 00:36:01.000000'
WHERE id = 100000700 AND @elapsed_seconds >= 2161;

UPDATE games
SET game_status = 'CANCELLED', updated_at = '2026-08-12 00:49:01.000000'
WHERE id = 1000008 AND @elapsed_seconds >= 2941;
