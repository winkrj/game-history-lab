package lab.gamehistory.cdc

import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Component

@Component
class CdcAffectedGameResolver(
    private val jdbcTemplate: JdbcTemplate,
) {

    fun resolve(record: ParsedDebeziumRecord): CdcAffectedGame {
        val gameId = when (record.reference.type) {
            CdcReferenceType.GAME_ID -> record.reference.id
            CdcReferenceType.ROUND_ID -> gameIdForRound(record.reference.id)
        }

        return CdcAffectedGame(
            gameId = gameId,
            sourceTable = record.sourceTable,
            operation = record.operation,
            sourceTimestampMillis = record.sourceTimestampMillis,
        )
    }

    private fun gameIdForRound(roundId: Long): Long {
        return jdbcTemplate.queryForObject(
            "SELECT game_id FROM rounds WHERE id = ?",
            Long::class.java,
            roundId,
        ) ?: throw IllegalStateException("Cannot resolve gameId for roundScore roundId=$roundId")
    }
}
