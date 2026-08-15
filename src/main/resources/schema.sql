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
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    CONSTRAINT fk_games_shop
        FOREIGN KEY (shop_id) REFERENCES shops (id),
    INDEX idx_games_shop_played_at (shop_id, played_at DESC, id DESC),
    INDEX idx_games_updated_at (updated_at, id)
);

CREATE TABLE IF NOT EXISTS rounds (
    id BIGINT NOT NULL AUTO_INCREMENT,
    game_id BIGINT NOT NULL,
    round_number INT NOT NULL,
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    CONSTRAINT fk_rounds_game
        FOREIGN KEY (game_id) REFERENCES games (id),
    CONSTRAINT uk_rounds_game_number
        UNIQUE (game_id, round_number),
    INDEX idx_rounds_updated_at (updated_at, game_id)
);

CREATE TABLE IF NOT EXISTS round_scores (
    id BIGINT NOT NULL AUTO_INCREMENT,
    round_id BIGINT NOT NULL,
    score INT NOT NULL,
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    CONSTRAINT fk_round_scores_round
        FOREIGN KEY (round_id) REFERENCES rounds (id),
    INDEX idx_round_scores_round_id (round_id),
    INDEX idx_round_scores_updated_at (updated_at, round_id)
);

CREATE TABLE IF NOT EXISTS game_history_read_model (
    game_id BIGINT NOT NULL,
    shop_id BIGINT NOT NULL,
    played_at DATETIME(6) NOT NULL,
    player_nickname VARCHAR(100) NOT NULL,
    course_name VARCHAR(100) NOT NULL,
    total_score BIGINT NOT NULL,
    round_count BIGINT NOT NULL,
    game_status VARCHAR(30) NOT NULL,
    PRIMARY KEY (game_id),
    INDEX idx_game_history_shop_played_at (shop_id, played_at DESC, game_id DESC)
);

CREATE TABLE IF NOT EXISTS incremental_read_model_checkpoint (
    checkpoint_name VARCHAR(100) NOT NULL,
    cursor_updated_at DATETIME(6) NOT NULL,
    cursor_game_id BIGINT NOT NULL,
    PRIMARY KEY (checkpoint_name)
);

INSERT INTO incremental_read_model_checkpoint (
    checkpoint_name,
    cursor_updated_at,
    cursor_game_id
)
VALUES ('game-history', '1970-01-01 00:00:00.000000', 0)
ON DUPLICATE KEY UPDATE checkpoint_name = checkpoint_name;
