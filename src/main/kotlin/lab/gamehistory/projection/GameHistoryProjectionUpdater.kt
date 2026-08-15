package lab.gamehistory.projection

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate
import org.springframework.stereotype.Component

@Component
class GameHistoryProjectionUpdater(
    private val jdbcTemplate: NamedParameterJdbcTemplate,
) {

    fun upsertGames(gameIds: Collection<Long>): Int {
        val distinctGameIds = gameIds.distinct()
        if (distinctGameIds.isEmpty()) {
            return 0
        }

        return jdbcTemplate.update(
            UPSERT_GAMES,
            MapSqlParameterSource("gameIds", distinctGameIds),
        )
    }

    private companion object {
        val UPSERT_GAMES = """
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
            WHERE g.id IN (:gameIds)
            GROUP BY
                g.id,
                g.shop_id,
                g.played_at,
                g.player_nickname,
                g.course_name,
                g.game_status
            ON DUPLICATE KEY UPDATE
                shop_id = VALUES(shop_id),
                played_at = VALUES(played_at),
                player_nickname = VALUES(player_nickname),
                course_name = VALUES(course_name),
                total_score = VALUES(total_score),
                round_count = VALUES(round_count),
                game_status = VALUES(game_status)
        """.trimIndent()
    }
}
