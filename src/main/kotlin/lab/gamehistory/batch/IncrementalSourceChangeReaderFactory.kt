package lab.gamehistory.batch

import org.springframework.batch.infrastructure.item.database.JdbcPagingItemReader
import org.springframework.batch.infrastructure.item.database.Order
import org.springframework.batch.infrastructure.item.database.builder.JdbcPagingItemReaderBuilder
import java.time.LocalDateTime
import javax.sql.DataSource

class IncrementalSourceChangeReaderFactory(
    private val dataSource: DataSource,
) {

    fun create(
        lowerUpdatedAt: LocalDateTime,
        lowerGameId: Long,
        upperUpdatedAt: LocalDateTime,
        upperGameId: Long,
        pageSize: Int,
    ): JdbcPagingItemReader<IncrementalSourceChange> =
        JdbcPagingItemReaderBuilder<IncrementalSourceChange>()
            .name(READER_NAME)
            .dataSource(dataSource)
            .selectClause("game_id, MAX(changed_at) AS changed_at")
            .fromClause(SOURCE_CHANGES)
            .groupClause("game_id")
            .sortKeys(linkedMapOf("changed_at" to Order.ASCENDING, "game_id" to Order.ASCENDING))
            .parameterValues(
                mapOf(
                    "lowerUpdatedAt" to lowerUpdatedAt,
                    "lowerGameId" to lowerGameId,
                    "upperUpdatedAt" to upperUpdatedAt,
                    "upperGameId" to upperGameId,
                ),
            )
            .pageSize(pageSize)
            .fetchSize(pageSize)
            .saveState(true)
            .rowMapper { resultSet, _ ->
                IncrementalSourceChange(
                    gameId = resultSet.getLong("game_id"),
                    changedAt = resultSet.getObject("changed_at", LocalDateTime::class.java),
                )
            }
            .build()

    private companion object {
        const val READER_NAME = "incrementalSourceChangeReader"

        val CHANGE_BOUNDS = """
            (
                updated_at > :lowerUpdatedAt
                OR (updated_at = :lowerUpdatedAt AND game_id > :lowerGameId)
            )
            AND (
                updated_at < :upperUpdatedAt
                OR (updated_at = :upperUpdatedAt AND game_id <= :upperGameId)
            )
        """.trimIndent()

        val SOURCE_CHANGES = """
            (
                SELECT g.id AS game_id, g.updated_at AS changed_at
                FROM games g
                WHERE ${CHANGE_BOUNDS.replace("game_id", "g.id")}

                UNION ALL

                SELECT r.game_id, r.updated_at AS changed_at
                FROM rounds r
                WHERE ${CHANGE_BOUNDS.replace("game_id", "r.game_id")}

                UNION ALL

                SELECT r.game_id, rs.updated_at AS changed_at
                FROM round_scores rs
                JOIN rounds r ON r.id = rs.round_id
                WHERE ${CHANGE_BOUNDS.replace("updated_at", "rs.updated_at").replace("game_id", "r.game_id")}
            ) source_changes
        """.trimIndent()
    }
}
