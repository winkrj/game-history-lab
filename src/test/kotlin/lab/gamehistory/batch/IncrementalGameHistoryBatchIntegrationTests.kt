package lab.gamehistory.batch

import lab.gamehistory.TestcontainersConfiguration
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.batch.core.BatchStatus
import org.springframework.batch.core.job.Job
import org.springframework.batch.core.job.parameters.JobParametersBuilder
import org.springframework.batch.core.launch.JobLauncher
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.beans.factory.annotation.Qualifier
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.context.annotation.Import
import org.springframework.core.io.ClassPathResource
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.datasource.init.ScriptUtils
import java.time.LocalDateTime
import java.util.UUID
import javax.sql.DataSource

@Import(TestcontainersConfiguration::class)
@SpringBootTest(properties = ["stage4.incremental.chunk-size=2"])
class IncrementalGameHistoryBatchIntegrationTests {

    @Autowired
    private lateinit var dataSource: DataSource

    @Autowired
    private lateinit var jobLauncher: JobLauncher

    @Autowired
    @Qualifier("incrementalGameHistoryReadModelJob")
    private lateinit var incrementalJob: Job

    @Autowired
    private lateinit var jdbcTemplate: JdbcTemplate

    @BeforeEach
    fun prepareFixture() {
        dataSource.connection.use { connection ->
            ScriptUtils.executeSqlScript(connection, ClassPathResource("original-game-history-fixture.sql"))
            ScriptUtils.executeSqlScript(connection, ClassPathResource("stage2-rebuild-read-model.sql"))
        }
        setCheckpoint(LOWER, 0)
    }

    @Test
    fun reflectsNewGameStatusAndScoreChangesWithoutAFullRebuild() {
        val changedAt = LocalDateTime.parse("2026-03-01T01:00:00")
        jdbcTemplate.update(
            "UPDATE games SET game_status = 'CANCELLED', updated_at = ? WHERE id = 100",
            changedAt,
        )
        jdbcTemplate.update(
            "UPDATE round_scores SET score = 123, updated_at = ? WHERE id = 5004",
            changedAt,
        )
        insertGame(300, changedAt)

        val execution = launch(UUID.randomUUID().toString(), UPPER)

        assertEquals(BatchStatus.COMPLETED, execution.status)
        val processing = execution.stepExecutions.single { it.stepName == "processIncrementalChangesStep" }
        assertEquals(3, processing.readCount)
        assertEquals(3, processing.writeCount)
        assertEquals("CANCELLED", value("SELECT game_status FROM game_history_read_model WHERE game_id = 100"))
        assertEquals(123L, longValue("SELECT total_score FROM game_history_read_model WHERE game_id = 200"))
        assertEquals(1L, longValue("SELECT round_count FROM game_history_read_model WHERE game_id = 300"))
        assertProjectionMatchesSource()
    }

    @Test
    fun keepsSameTimestampBoundariesAndReplaySafe() {
        val boundary = LocalDateTime.parse("2026-03-01T02:00:00")
        jdbcTemplate.update("UPDATE games SET game_status = 'BOUNDARY', updated_at = ? WHERE id IN (100, 101, 102)", boundary)
        setCheckpoint(boundary, 100)

        val first = launch(UUID.randomUUID().toString(), boundary)
        assertEquals(BatchStatus.COMPLETED, first.status)
        assertEquals(2, first.stepExecutions.first { it.stepName == "processIncrementalChangesStep" }.writeCount)
        assertEquals("COMPLETED", value("SELECT game_status FROM game_history_read_model WHERE game_id = 100"))
        assertEquals("BOUNDARY", value("SELECT game_status FROM game_history_read_model WHERE game_id = 101"))
        assertEquals("BOUNDARY", value("SELECT game_status FROM game_history_read_model WHERE game_id = 102"))

        setCheckpoint(boundary.minusMinutes(5), 0)
        val replay = launch(UUID.randomUUID().toString(), boundary)
        assertEquals(BatchStatus.COMPLETED, replay.status)
        assertEquals(3, replay.stepExecutions.first { it.stepName == "processIncrementalChangesStep" }.writeCount)
        val afterReplay = projectionFingerprint()
        setCheckpoint(boundary.minusMinutes(5), 0)
        val repeatedReplay = launch(UUID.randomUUID().toString(), boundary)
        assertEquals(BatchStatus.COMPLETED, repeatedReplay.status)
        assertEquals(afterReplay, projectionFingerprint())
        assertProjectionMatchesSource()
    }

    @Test
    fun restartsAtTheLastCommittedChunkAndAdvancesTheDurableCursorOnlyAfterSuccess() {
        val changedAt = LocalDateTime.parse("2026-03-01T03:00:00")
        jdbcTemplate.update("UPDATE games SET game_status = 'UPDATED', updated_at = ?", changedAt)
        insertGame(300, changedAt)
        insertGame(301, changedAt)
        insertGame(302, changedAt)
        val runId = UUID.randomUUID().toString()

        val failed = launch(runId, UPPER, failAfterCount = 6)

        assertEquals(BatchStatus.FAILED, failed.status)
        val failedStep = failed.stepExecutions.single()
        assertEquals(4, failedStep.writeCount)
        assertEquals(1, failedStep.rollbackCount)
        assertEquals(LOWER, checkpointUpdatedAt())

        val restarted = launch(runId, UPPER)

        assertEquals(BatchStatus.COMPLETED, restarted.status)
        assertEquals(failed.jobInstanceId, restarted.jobInstanceId)
        assertNotEquals(failed.id, restarted.id)
        assertEquals(4, restarted.stepExecutions.first { it.stepName == "processIncrementalChangesStep" }.writeCount)
        assertEquals(UPPER, checkpointUpdatedAt())
        assertProjectionMatchesSource()
    }

    private fun launch(runId: String, upper: LocalDateTime, failAfterCount: Long = 0) =
        jobLauncher.run(
            incrementalJob,
            JobParametersBuilder()
                .addString("runId", runId)
                .addLocalDateTime("lowerUpdatedAt", checkpointUpdatedAt())
                .addLong("lowerGameId", checkpointGameId())
                .addLocalDateTime("upperUpdatedAt", upper)
                .addLong("upperGameId", Long.MAX_VALUE)
                .addLong("failAfterCount", failAfterCount, false)
                .toJobParameters(),
        )

    private fun insertGame(gameId: Long, updatedAt: LocalDateTime) {
        jdbcTemplate.update(
            """
                INSERT INTO games
                    (id, shop_id, played_at, player_nickname, course_name, game_status, updated_at)
                VALUES (?, 1, '2026-01-15 00:00:00', ?, 'Incremental Course', 'COMPLETED', ?)
            """.trimIndent(),
            gameId,
            "player-$gameId",
            updatedAt,
        )
        jdbcTemplate.update(
            "INSERT INTO rounds (id, game_id, round_number, updated_at) VALUES (?, ?, 1, ?)",
            gameId * 10,
            gameId,
            updatedAt,
        )
        jdbcTemplate.update(
            "INSERT INTO round_scores (id, round_id, score, updated_at) VALUES (?, ?, 10, ?)",
            gameId * 100,
            gameId * 10,
            updatedAt,
        )
    }

    private fun setCheckpoint(updatedAt: LocalDateTime, gameId: Long) {
        jdbcTemplate.update(
            "UPDATE incremental_read_model_checkpoint SET cursor_updated_at = ?, cursor_game_id = ? WHERE checkpoint_name = 'game-history'",
            updatedAt,
            gameId,
        )
    }

    private fun checkpointUpdatedAt(): LocalDateTime = jdbcTemplate.queryForObject(
        "SELECT cursor_updated_at FROM incremental_read_model_checkpoint WHERE checkpoint_name = 'game-history'",
        LocalDateTime::class.java,
    )!!

    private fun checkpointGameId(): Long = longValue(
        "SELECT cursor_game_id FROM incremental_read_model_checkpoint WHERE checkpoint_name = 'game-history'",
    )

    private fun value(sql: String): String = jdbcTemplate.queryForObject(sql, String::class.java)!!

    private fun longValue(sql: String): Long = jdbcTemplate.queryForObject(sql, Long::class.java)!!

    private fun projectionFingerprint(): String = jdbcTemplate.queryForObject(
        """
            SELECT GROUP_CONCAT(CONCAT(game_id, ':', game_status, ':', total_score) ORDER BY game_id SEPARATOR '|')
            FROM game_history_read_model
        """.trimIndent(),
        String::class.java,
    )!!

    private fun assertProjectionMatchesSource() {
        assertEquals(
            0L,
            longValue(
                """
                    SELECT COUNT(*)
                    FROM (
                        SELECT
                            g.id AS game_id,
                            g.shop_id,
                            g.played_at,
                            g.player_nickname,
                            g.course_name,
                            COALESCE(SUM(rs.score), 0) AS total_score,
                            COUNT(DISTINCT r.id) AS round_count,
                            g.game_status
                        FROM games g
                        LEFT JOIN rounds r ON r.game_id = g.id
                        LEFT JOIN round_scores rs ON rs.round_id = r.id
                        GROUP BY g.id, g.shop_id, g.played_at, g.player_nickname, g.course_name, g.game_status
                    ) source_projection
                    LEFT JOIN game_history_read_model rm ON rm.game_id = source_projection.game_id
                    WHERE rm.game_id IS NULL
                       OR rm.shop_id <> source_projection.shop_id
                       OR rm.played_at <> source_projection.played_at
                       OR rm.player_nickname <> source_projection.player_nickname
                       OR rm.course_name <> source_projection.course_name
                       OR rm.total_score <> source_projection.total_score
                       OR rm.round_count <> source_projection.round_count
                       OR rm.game_status <> source_projection.game_status
                """.trimIndent(),
            ),
        )
        assertEquals(longValue("SELECT COUNT(*) FROM games"), longValue("SELECT COUNT(*) FROM game_history_read_model"))
    }

    private companion object {
        val LOWER: LocalDateTime = LocalDateTime.parse("2026-03-01T00:00:00")
        val UPPER: LocalDateTime = LocalDateTime.parse("2026-03-02T00:00:00")
    }
}
