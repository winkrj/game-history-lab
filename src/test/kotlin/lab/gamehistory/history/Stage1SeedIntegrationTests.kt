package lab.gamehistory.history

import lab.gamehistory.TestcontainersConfiguration
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc
import org.springframework.context.annotation.Import
import org.springframework.core.io.ClassPathResource
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.datasource.init.ScriptUtils
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import java.sql.Connection
import java.time.Instant
import javax.sql.DataSource

@Import(TestcontainersConfiguration::class)
@SpringBootTest
@AutoConfigureMockMvc
class Stage1SeedIntegrationTests {

    @Autowired
    private lateinit var dataSource: DataSource

    @Autowired
    private lateinit var jdbcTemplate: JdbcTemplate

    @Autowired
    private lateinit var query: OriginalGameHistoryQuery

    @Autowired
    private lateinit var mockMvc: MockMvc

    @Test
    fun generatesDeterministicRelatedDataAndSupportsTheExistingApi() {
        generateSmallDataSet()

        assertEquals(100, countRows("shops"))
        assertEquals(200, countRows("games"))
        assertEquals(720, countRows("rounds"))
        assertEquals(1380, countRows("round_scores"))
        assertEquals(0, countOrphans())
        assertEquals(20, countGamesForShop(1))
        assertTrue(countGamesForShop(1) > countGamesForShop(2))
        assertEquals(200, countDistinctPlayedAt())

        val firstSnapshot = sourceSnapshot()
        val expected = query.findByShopAndPeriod(
            shopId = 1,
            fromInclusive = Instant.parse("2025-01-01T00:00:00Z"),
            toExclusive = Instant.parse("2026-01-01T00:00:00Z"),
            limit = 20,
            offset = 0,
        )

        assertEquals(20, expected.size)

        mockMvc.perform(
            get("/shops/{shopId}/games", 1)
                .param("from", "2025-01-01T00:00:00Z")
                .param("to", "2026-01-01T00:00:00Z")
                .param("page", "0")
                .param("size", "20")
                .param("queryMode", "original"),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.length()").value(20))
            .andExpect(jsonPath("$[0].gameId").value(expected.first().gameId))
            .andExpect(jsonPath("$[0].playedAt").value(expected.first().playedAt.toString()))
            .andExpect(jsonPath("$[0].totalScore").value(expected.first().totalScore))
            .andExpect(jsonPath("$[0].roundCount").value(expected.first().roundCount))
            .andExpect(jsonPath("$[0].gameStatus").value(expected.first().gameStatus))

        generateSmallDataSet()

        assertEquals(firstSnapshot, sourceSnapshot())
    }

    private fun generateSmallDataSet() {
        dataSource.connection.use { connection ->
            setSeedVariables(connection)
            ScriptUtils.executeSqlScript(connection, ClassPathResource("stage1-seed.sql"))
        }
    }

    private fun setSeedVariables(connection: Connection) {
        connection.createStatement().use { statement ->
            statement.execute("SET @game_count = 200")
            statement.execute("SET @seed = 20260810")
        }
    }

    private fun countRows(tableName: String): Int {
        return jdbcTemplate.queryForObject("SELECT COUNT(*) FROM $tableName", Int::class.java)!!
    }

    private fun countGamesForShop(shopId: Long): Int {
        return jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM games WHERE shop_id = ?",
            Int::class.java,
            shopId,
        )!!
    }

    private fun countDistinctPlayedAt(): Int {
        return jdbcTemplate.queryForObject(
            "SELECT COUNT(DISTINCT played_at) FROM games",
            Int::class.java,
        )!!
    }

    private fun countOrphans(): Int {
        return jdbcTemplate.queryForObject(
            """
                SELECT
                    (SELECT COUNT(*) FROM games game
                     LEFT JOIN shops shop ON shop.id = game.shop_id
                     WHERE shop.id IS NULL)
                    + (SELECT COUNT(*) FROM rounds round_row
                       LEFT JOIN games game ON game.id = round_row.game_id
                       WHERE game.id IS NULL)
                    + (SELECT COUNT(*) FROM round_scores score
                       LEFT JOIN rounds round_row ON round_row.id = score.round_id
                       WHERE round_row.id IS NULL)
            """.trimIndent(),
            Int::class.java,
        )!!
    }

    private fun sourceSnapshot(): List<String> {
        val games = jdbcTemplate.query(
            """
                SELECT id, shop_id, played_at, player_nickname, course_name, game_status
                FROM games
                ORDER BY id
            """.trimIndent(),
        ) { resultSet, _ ->
            listOf(
                "game",
                resultSet.getLong("id"),
                resultSet.getLong("shop_id"),
                resultSet.getString("played_at"),
                resultSet.getString("player_nickname"),
                resultSet.getString("course_name"),
                resultSet.getString("game_status"),
            ).joinToString("|")
        }
        val rounds = jdbcTemplate.query(
            "SELECT id, game_id, round_number FROM rounds ORDER BY id",
        ) { resultSet, _ ->
            "round|${resultSet.getLong("id")}|${resultSet.getLong("game_id")}|${resultSet.getInt("round_number")}"
        }
        val scores = jdbcTemplate.query(
            "SELECT id, round_id, score FROM round_scores ORDER BY id",
        ) { resultSet, _ ->
            "score|${resultSet.getLong("id")}|${resultSet.getLong("round_id")}|${resultSet.getInt("score")}"
        }

        return games + rounds + scores
    }
}
