package lab.gamehistory.cdc

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import tools.jackson.databind.ObjectMapper

class DebeziumRecordParserTests {

    private val parser = DebeziumRecordParser(ObjectMapper())

    @Test
    fun prefersAfterRowAndParsesGameAndRoundReferences() {
        val game = parser.parse(
            """
                {
                  "before": {"id":99},
                  "after": {"id":100},
                  "source": {"table":"games","ts_ms":1786550400000},
                  "op":"u"
                }
            """.trimIndent(),
        )
        val round = parser.parse(
            """
                {
                  "payload": {
                    "before": null,
                    "after": {"id":1003,"game_id":100},
                    "source": {"table":"rounds","ts_ms":1786550400000},
                    "op":"c"
                  }
                }
            """.trimIndent(),
        )

        assertEquals(
            ParsedDebeziumRecord(
                sourceTable = "games",
                operation = "u",
                reference = CdcEntityReference(CdcReferenceType.GAME_ID, 100),
                sourceTimestampMillis = 1786550400000,
            ),
            game,
        )
        assertEquals(CdcEntityReference(CdcReferenceType.GAME_ID, 100), round?.reference)
        assertEquals("c", round?.operation)
    }

    @Test
    fun fallsBackToBeforeRowForRoundScoreReference() {
        val parsed = parser.parse(
            """
                {
                  "before": {"id":5004,"round_id":2001},
                  "after": null,
                  "source": {"table":"round_scores","ts_ms":1786550400001},
                  "op":"d"
                }
            """.trimIndent(),
        )

        assertEquals(CdcEntityReference(CdcReferenceType.ROUND_ID, 2001), parsed?.reference)
        assertEquals("d", parsed?.operation)
    }

    @Test
    fun ignoresRecordsThatDoNotDescribeACapturedChange() {
        assertNull(parser.parse(null))
        assertNull(parser.parse("  "))
        assertNull(parser.parse(event("shops", "u", "\"id\":1")))
        assertNull(parser.parse(event("games", "", "\"id\":100")))
    }

    private fun event(table: String, operation: String, rowFields: String): String = """
        {
          "before": null,
          "after": {$rowFields},
          "source": {"table": "$table", "ts_ms": 1786550400000},
          "op": "$operation"
        }
    """.trimIndent()
}
