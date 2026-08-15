DELETE FROM game_history_read_model;
DELETE FROM incremental_read_model_checkpoint;
DELETE FROM round_scores;
DELETE FROM rounds;
DELETE FROM games;
DELETE FROM shops;

INSERT INTO shops (id, name)
VALUES (1, 'Seoul Shop'),
       (2, 'Busan Shop');

INSERT INTO games (id, shop_id, played_at, player_nickname, course_name, game_status, updated_at)
VALUES (100, 1, '2026-01-03 10:00:00.000000', 'alice', 'Lake Course', 'COMPLETED', '2026-01-03 10:00:00.000000'),
       (101, 1, '2026-01-03 10:00:00.000000', 'bob', 'Hill Course', 'CANCELLED', '2026-01-03 10:00:00.000000'),
       (102, 1, '2026-01-01 00:00:00.000000', 'carol', 'Forest Course', 'IN_PROGRESS', '2026-01-01 00:00:00.000000'),
       (103, 1, '2026-02-01 00:00:00.000000', 'dave', 'Ocean Course', 'COMPLETED', '2026-02-01 00:00:00.000000'),
       (200, 2, '2026-01-04 10:00:00.000000', 'erin', 'River Course', 'COMPLETED', '2026-01-04 10:00:00.000000');

INSERT INTO rounds (id, game_id, round_number, updated_at)
VALUES (1001, 100, 1, '2026-01-03 10:00:00.000000'),
       (1002, 100, 2, '2026-01-03 10:00:00.000000'),
       (1021, 102, 1, '2026-01-01 00:00:00.000000'),
       (2001, 200, 1, '2026-01-04 10:00:00.000000');

INSERT INTO round_scores (id, round_id, score, updated_at)
VALUES (5001, 1001, 10, '2026-01-03 10:00:00.000000'),
       (5002, 1001, 20, '2026-01-03 10:00:00.000000'),
       (5003, 1002, -5, '2026-01-03 10:00:00.000000'),
       (5004, 2001, 99, '2026-01-04 10:00:00.000000');

INSERT INTO incremental_read_model_checkpoint (
    checkpoint_name,
    cursor_updated_at,
    cursor_game_id
)
VALUES ('game-history', '1970-01-01 00:00:00.000000', 0);
