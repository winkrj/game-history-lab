package lab.gamehistory.batch

import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Component
import java.time.LocalDateTime

@Component
class IncrementalCheckpointStore(
    private val jdbcTemplate: JdbcTemplate,
) {

    fun current(): IncrementalCursor {
        val cursor = jdbcTemplate.queryForObject(
            """
                SELECT cursor_updated_at, cursor_game_id
                FROM incremental_read_model_checkpoint
                WHERE checkpoint_name = 'game-history'
            """.trimIndent(),
        ) { resultSet, _ ->
            IncrementalCursor(
                updatedAt = resultSet.getObject("cursor_updated_at", LocalDateTime::class.java),
                gameId = resultSet.getLong("cursor_game_id"),
            )
        }
        return cursor
    }

    fun advanceTo(cursor: IncrementalCursor) {
        jdbcTemplate.update(
            """
                UPDATE incremental_read_model_checkpoint
                SET cursor_updated_at = ?, cursor_game_id = ?
                WHERE checkpoint_name = 'game-history'
                  AND (
                      cursor_updated_at < ?
                      OR (cursor_updated_at = ? AND cursor_game_id < ?)
                  )
            """.trimIndent(),
            cursor.updatedAt,
            cursor.gameId,
            cursor.updatedAt,
            cursor.updatedAt,
            cursor.gameId,
        )
    }
}

data class IncrementalCursor(
    val updatedAt: LocalDateTime,
    val gameId: Long,
)
