package lab.gamehistory.cdc

import lab.gamehistory.TestcontainersConfiguration
import lab.gamehistory.projection.GameHistoryProjectionUpdater
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.context.annotation.Import
import org.springframework.core.io.ClassPathResource
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.datasource.init.ScriptUtils
import javax.sql.DataSource

@Import(TestcontainersConfiguration::class)
@SpringBootTest
class CdcProjectionIntegrationTests {

    @Autowired
    private lateinit var dataSource: DataSource

    @Autowired
    private lateinit var jdbcTemplate: JdbcTemplate

    @Autowired
    private lateinit var affectedGameResolver: CdcAffectedGameResolver

    @Autowired
    private lateinit var projectionUpdater: GameHistoryProjectionUpdater

    @BeforeEach
    fun prepareFixture() {
        dataSource.connection.use { connection ->
            ScriptUtils.executeSqlScript(connection, ClassPathResource("original-game-history-fixture.sql"))
            ScriptUtils.executeSqlScript(connection, ClassPathResource("stage2-rebuild-read-model.sql"))
        }
    }

    @Test
    fun resolvesAffectedGameFromEachCapturedTableAndReusesOneProjectionUpdater() {
        jdbcTemplate.update("UPDATE games SET game_status = 'CANCELLED' WHERE id = 100")
        val gameChange = affectedGameResolver.resolve(event("games", "u", "\"id\":100"))!!
        assertEquals(100L, gameChange.gameId)
        projectionUpdater.upsertGames(listOf(gameChange.gameId))
        assertEquals("CANCELLED", value("SELECT game_status FROM game_history_read_model WHERE game_id = 100"))

        jdbcTemplate.update("INSERT INTO rounds (id, game_id, round_number) VALUES (1003, 100, 3)")
        val roundChange = affectedGameResolver.resolve(event("rounds", "c", "\"id\":1003,\"game_id\":100"))!!
        assertEquals(100L, roundChange.gameId)
        projectionUpdater.upsertGames(listOf(roundChange.gameId))
        assertEquals(3L, longValue("SELECT round_count FROM game_history_read_model WHERE game_id = 100"))

        jdbcTemplate.update("UPDATE round_scores SET score = 111 WHERE id = 5004")
        val scoreChange = affectedGameResolver.resolve(event("round_scores", "u", "\"id\":5004,\"round_id\":2001"))!!
        assertEquals(200L, scoreChange.gameId)
        projectionUpdater.upsertGames(listOf(scoreChange.gameId))
        assertEquals(111L, longValue("SELECT total_score FROM game_history_read_model WHERE game_id = 200"))
    }

    @Test
    fun replayingTheSameAffectedGameKeepsTheProjectionStable() {
        jdbcTemplate.update("UPDATE round_scores SET score = 55 WHERE id = 5001")
        val change = affectedGameResolver.resolve(event("round_scores", "u", "\"id\":5001,\"round_id\":1001"))!!

        projectionUpdater.upsertGames(listOf(change.gameId))
        val first = fingerprint(change.gameId)
        projectionUpdater.upsertGames(listOf(change.gameId))

        assertEquals(first, fingerprint(change.gameId))
        assertEquals(70L, longValue("SELECT total_score FROM game_history_read_model WHERE game_id = 100"))
    }

    private fun event(table: String, operation: String, rowFields: String): String = """
        {
          "before": null,
          "after": {$rowFields},
          "source": {"table": "$table", "ts_ms": 1786550400000},
          "op": "$operation"
        }
    """.trimIndent()

    private fun value(sql: String): String = jdbcTemplate.queryForObject(sql, String::class.java)!!

    private fun longValue(sql: String): Long = jdbcTemplate.queryForObject(sql, Long::class.java)!!

    private fun fingerprint(gameId: Long): String = jdbcTemplate.queryForObject(
        """
            SELECT CONCAT_WS('|', game_id, shop_id, played_at, player_nickname,
                course_name, total_score, round_count, game_status)
            FROM game_history_read_model
            WHERE game_id = ?
        """.trimIndent(),
        String::class.java,
        gameId,
    )!!
}
