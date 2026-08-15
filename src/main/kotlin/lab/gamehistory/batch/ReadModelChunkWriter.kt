package lab.gamehistory.batch

import org.springframework.batch.infrastructure.item.Chunk
import org.springframework.batch.infrastructure.item.ItemWriter
import org.springframework.jdbc.core.JdbcTemplate

class ReadModelChunkWriter(
    private val jdbcTemplate: JdbcTemplate,
) : ItemWriter<Long> {

    override fun write(chunk: Chunk<out Long>) {
        if (chunk.isEmpty) {
            return
        }

        val firstGameId = chunk.items.first()
        val lastGameId = chunk.items.last()
        jdbcTemplate.update(UPSERT_RANGE, firstGameId, lastGameId)
    }

    private companion object {
        val UPSERT_RANGE = """
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
            WHERE g.id BETWEEN ? AND ?
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
