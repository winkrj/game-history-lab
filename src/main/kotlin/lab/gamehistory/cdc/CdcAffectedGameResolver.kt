package lab.gamehistory.cdc

import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Component
import tools.jackson.databind.JsonNode
import tools.jackson.databind.ObjectMapper

@Component
class CdcAffectedGameResolver(
    private val objectMapper: ObjectMapper,
    private val jdbcTemplate: JdbcTemplate,
) {

    fun resolve(value: String?): CdcAffectedGame? {
        if (value.isNullOrBlank()) {
            return null
        }

        val root = objectMapper.readTree(value)
        val event = root.get("payload") ?: root
        val operation = event.path("op").asText()
        if (operation.isBlank()) {
            return null
        }

        val source = event.path("source")
        val table = source.path("table").asText()
        val row = currentRow(event) ?: return null
        val gameId = when (table) {
            "games" -> requiredLong(row, "id")
            "rounds" -> requiredLong(row, "game_id")
            "round_scores" -> gameIdForRound(requiredLong(row, "round_id"))
            else -> return null
        }

        return CdcAffectedGame(
            gameId = gameId,
            sourceTable = table,
            operation = operation,
            sourceTimestampMillis = source.path("ts_ms").takeUnless { it.isMissingNode || it.isNull }?.asLong(),
        )
    }

    private fun currentRow(event: JsonNode): JsonNode? {
        val after = event.path("after")
        if (!after.isMissingNode && !after.isNull) {
            return after
        }
        val before = event.path("before")
        return before.takeUnless { it.isMissingNode || it.isNull }
    }

    private fun requiredLong(row: JsonNode, field: String): Long {
        val value = row.path(field)
        require(!value.isMissingNode && !value.isNull) { "CDC row is missing $field" }
        return value.asLong()
    }

    private fun gameIdForRound(roundId: Long): Long {
        return jdbcTemplate.queryForObject(
            "SELECT game_id FROM rounds WHERE id = ?",
            Long::class.java,
            roundId,
        ) ?: throw IllegalStateException("Cannot resolve gameId for roundScore roundId=$roundId")
    }
}
