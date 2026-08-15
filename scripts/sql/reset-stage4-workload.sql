DELETE FROM game_history_read_model WHERE game_id BETWEEN 1000001 AND 1000008;
DELETE FROM round_scores WHERE id BETWEEN 100000100 AND 100000800;
DELETE FROM rounds WHERE id BETWEEN 10000010 AND 10000080;
DELETE FROM games WHERE id BETWEEN 1000001 AND 1000008;

INSERT INTO games (
    id, shop_id, played_at, player_nickname, course_name, game_status, updated_at
)
SELECT
    sequence.n,
    1,
    TIMESTAMP('2025-12-30 12:00:00.000000') + INTERVAL (sequence.n - 1000000) SECOND,
    CONCAT('stage4-player-', sequence.n),
    'Stage 4 Course',
    'COMPLETED',
    '2026-08-12 00:00:00.000000'
FROM (
    SELECT 1000002 AS n UNION ALL SELECT 1000003 UNION ALL SELECT 1000004
    UNION ALL SELECT 1000005 UNION ALL SELECT 1000006 UNION ALL SELECT 1000007
    UNION ALL SELECT 1000008
) sequence;

INSERT INTO rounds (id, game_id, round_number, updated_at)
SELECT id * 10, id, 1, '2026-08-12 00:00:00.000000'
FROM games
WHERE id BETWEEN 1000002 AND 1000008;

INSERT INTO round_scores (id, round_id, score, updated_at)
SELECT id * 10, id, 10, '2026-08-12 00:00:00.000000'
FROM rounds
WHERE game_id BETWEEN 1000002 AND 1000008;

INSERT INTO game_history_read_model (
    game_id, shop_id, played_at, player_nickname, course_name,
    total_score, round_count, game_status
)
SELECT
    g.id, g.shop_id, g.played_at, g.player_nickname, g.course_name,
    COALESCE(SUM(rs.score), 0), COUNT(DISTINCT r.id), g.game_status
FROM games g
LEFT JOIN rounds r ON r.game_id = g.id
LEFT JOIN round_scores rs ON rs.round_id = r.id
WHERE g.id BETWEEN 1000002 AND 1000008
GROUP BY g.id, g.shop_id, g.played_at, g.player_nickname, g.course_name, g.game_status;

UPDATE incremental_read_model_checkpoint
SET cursor_updated_at = '2026-08-12 00:00:00.000000', cursor_game_id = 0
WHERE checkpoint_name = 'game-history';
