SET @read_model_build_started_at = NOW(6);

TRUNCATE TABLE game_history_read_model;

INSERT INTO game_history_read_model (
    game_id,
    shop_id,
    played_at,
    player_nickname,
    course_name,
    total_score,
    round_count,
    game_status
)
SELECT
    g.id,
    g.shop_id,
    g.played_at,
    g.player_nickname,
    g.course_name,
    COALESCE(SUM(rs.score), 0),
    COUNT(DISTINCT r.id),
    g.game_status
FROM games g
LEFT JOIN rounds r ON r.game_id = g.id
LEFT JOIN round_scores rs ON rs.round_id = r.id
GROUP BY
    g.id,
    g.shop_id,
    g.played_at,
    g.player_nickname,
    g.course_name,
    g.game_status;

SELECT
    COUNT(*) AS read_model_rows,
    TIMESTAMPDIFF(MICROSECOND, @read_model_build_started_at, NOW(6)) / 1000000 AS build_seconds
FROM game_history_read_model;
