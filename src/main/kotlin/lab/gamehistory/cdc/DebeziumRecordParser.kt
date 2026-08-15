package lab.gamehistory.cdc

import org.springframework.stereotype.Component
import tools.jackson.databind.JsonNode
import tools.jackson.databind.ObjectMapper

@Component
class DebeziumRecordParser(
    private val objectMapper: ObjectMapper,
) {

    fun parse(value: String?): ParsedDebeziumRecord? {
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
        val sourceTable = source.path("table").asText()
        val row = currentRow(event) ?: return null
        val reference = when (sourceTable) {
            "games" -> CdcEntityReference(CdcReferenceType.GAME_ID, requiredLong(row, "id"))
            "rounds" -> CdcEntityReference(CdcReferenceType.GAME_ID, requiredLong(row, "game_id"))
            "round_scores" -> CdcEntityReference(CdcReferenceType.ROUND_ID, requiredLong(row, "round_id"))
            else -> return null
        }

        return ParsedDebeziumRecord(
            sourceTable = sourceTable,
            operation = operation,
            reference = reference,
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
}

data class ParsedDebeziumRecord(
    val sourceTable: String,
    val operation: String,
    val reference: CdcEntityReference,
    val sourceTimestampMillis: Long?,
)

data class CdcEntityReference(
    val type: CdcReferenceType,
    val id: Long,
)

enum class CdcReferenceType {
    GAME_ID,
    ROUND_ID,
}
