DELETE FROM game_history_read_model;
DELETE FROM round_scores;
DELETE FROM rounds;
DELETE FROM games;
DELETE FROM shops;

INSERT INTO shops (id, name)
VALUES (1, 'Seoul Shop'),
       (2, 'Busan Shop');

INSERT INTO games (id, shop_id, played_at, player_nickname, course_name, game_status)
VALUES (100, 1, '2026-01-03 10:00:00.000000', 'alice', 'Lake Course', 'COMPLETED'),
       (101, 1, '2026-01-03 10:00:00.000000', 'bob', 'Hill Course', 'CANCELLED'),
       (102, 1, '2026-01-01 00:00:00.000000', 'carol', 'Forest Course', 'IN_PROGRESS'),
       (103, 1, '2026-02-01 00:00:00.000000', 'dave', 'Ocean Course', 'COMPLETED'),
       (200, 2, '2026-01-04 10:00:00.000000', 'erin', 'River Course', 'COMPLETED');

INSERT INTO rounds (id, game_id, round_number)
VALUES (1001, 100, 1),
       (1002, 100, 2),
       (1021, 102, 1),
       (2001, 200, 1);

INSERT INTO round_scores (id, round_id, score)
VALUES (5001, 1001, 10),
       (5002, 1001, 20),
       (5003, 1002, -5),
       (5004, 2001, 99);

