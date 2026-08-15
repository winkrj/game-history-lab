-- Replaces all Source data in the current database.
-- The caller must set @game_count and @seed in this same MySQL session.

SET @game_count = COALESCE(@game_count, 1000000);
SET @seed = COALESCE(@seed, 20260810);

SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE game_history_read_model;
TRUNCATE TABLE incremental_read_model_checkpoint;
TRUNCATE TABLE round_scores;
TRUNCATE TABLE rounds;
TRUNCATE TABLE games;
TRUNCATE TABLE shops;
SET FOREIGN_KEY_CHECKS = 1;

DROP TEMPORARY TABLE IF EXISTS seed_numbers;
CREATE TEMPORARY TABLE seed_numbers (
    number_value INT UNSIGNED NOT NULL,
    PRIMARY KEY (number_value)
) ENGINE = InnoDB;

INSERT INTO seed_numbers (number_value)
WITH RECURSIVE
low_numbers (number_value) AS (
    SELECT 0
    UNION ALL
    SELECT number_value + 1
    FROM low_numbers
    WHERE number_value < 999
),
high_numbers (number_value) AS (
    SELECT 0
    UNION ALL
    SELECT number_value + 1
    FROM high_numbers
    WHERE number_value < 999
)
SELECT
    low_numbers.number_value + high_numbers.number_value * 1000
FROM low_numbers
CROSS JOIN high_numbers
WHERE low_numbers.number_value + high_numbers.number_value * 1000 < GREATEST(@game_count, 100);

INSERT INTO shops (id, name)
SELECT
    shop_number.number_value + 1,
    CONCAT('shop-', LPAD(shop_number.number_value + 1, 3, '0'))
FROM seed_numbers shop_number
WHERE shop_number.number_value < 100;

INSERT INTO games (
    id,
    shop_id,
    played_at,
    player_nickname,
    course_name,
    game_status,
    updated_at
)
SELECT
    game_number.number_value + 1,
    CASE
        WHEN MOD(game_number.number_value + @seed, 10) = 0 THEN 1
        ELSE 2 + MOD(game_number.number_value * 37 + @seed, 99)
    END,
    DATE_ADD(
        '2025-01-01 00:00:00',
        INTERVAL MOD(game_number.number_value * 104729 + @seed, 31536000) SECOND
    ),
    CONCAT('player-', LPAD(MOD(game_number.number_value * 17 + @seed, 200000), 6, '0')),
    CONCAT('course-', LPAD(MOD(game_number.number_value * 13 + @seed, 20) + 1, 2, '0')),
    CASE
        WHEN MOD(FLOOR(game_number.number_value / 10) + @seed, 20) = 0 THEN 'CANCELLED'
        WHEN MOD(FLOOR(game_number.number_value / 10) + @seed, 20) IN (1, 2) THEN 'IN_PROGRESS'
        ELSE 'COMPLETED'
    END,
    DATE_ADD(
        '2025-01-01 00:00:00',
        INTERVAL MOD(game_number.number_value * 104729 + @seed, 31536000) SECOND
    )
FROM seed_numbers game_number
WHERE game_number.number_value < @game_count;

INSERT INTO rounds (id, game_id, round_number, updated_at)
SELECT
    (game.id - 1) * 4 + round_sequence.round_number,
    game.id,
    round_sequence.round_number,
    game.updated_at
FROM games game
JOIN (
    SELECT 1 AS round_number
    UNION ALL SELECT 2
    UNION ALL SELECT 3
    UNION ALL SELECT 4
) round_sequence
    ON round_sequence.round_number <= CASE game.game_status
        WHEN 'IN_PROGRESS' THEN 2
        WHEN 'COMPLETED' THEN 4
        ELSE 0
    END;

INSERT INTO round_scores (id, round_id, score, updated_at)
SELECT
    (round_row.id - 1) * 2 + score_sequence.score_position,
    round_row.id,
    MOD(round_row.id * 31 + score_sequence.score_position * 7 + @seed, 11) - 5,
    game.updated_at
FROM rounds round_row
JOIN games game ON game.id = round_row.game_id
JOIN (
    SELECT 1 AS score_position
    UNION ALL SELECT 2
) score_sequence
    ON game.game_status = 'COMPLETED'
        OR (
            game.game_status = 'IN_PROGRESS'
            AND round_row.round_number = 1
            AND score_sequence.score_position = 1
        );

DROP TEMPORARY TABLE seed_numbers;

INSERT INTO incremental_read_model_checkpoint (
    checkpoint_name,
    cursor_updated_at,
    cursor_game_id
)
VALUES ('game-history', '1970-01-01 00:00:00.000000', 0);
