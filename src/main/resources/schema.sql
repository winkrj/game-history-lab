CREATE TABLE IF NOT EXISTS shops (
    id BIGINT NOT NULL AUTO_INCREMENT,
    name VARCHAR(100) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE IF NOT EXISTS games (
    id BIGINT NOT NULL AUTO_INCREMENT,
    shop_id BIGINT NOT NULL,
    played_at DATETIME(6) NOT NULL,
    player_nickname VARCHAR(100) NOT NULL,
    course_name VARCHAR(100) NOT NULL,
    game_status VARCHAR(30) NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_games_shop
        FOREIGN KEY (shop_id) REFERENCES shops (id),
    INDEX idx_games_shop_played_at (shop_id, played_at DESC, id DESC)
);

CREATE TABLE IF NOT EXISTS rounds (
    id BIGINT NOT NULL AUTO_INCREMENT,
    game_id BIGINT NOT NULL,
    round_number INT NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_rounds_game
        FOREIGN KEY (game_id) REFERENCES games (id),
    CONSTRAINT uk_rounds_game_number
        UNIQUE (game_id, round_number)
);

CREATE TABLE IF NOT EXISTS round_scores (
    id BIGINT NOT NULL AUTO_INCREMENT,
    round_id BIGINT NOT NULL,
    score INT NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_round_scores_round
        FOREIGN KEY (round_id) REFERENCES rounds (id),
    INDEX idx_round_scores_round_id (round_id)
);
