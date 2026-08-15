package lab.gamehistory.batch

import lab.gamehistory.TestcontainersConfiguration
import lab.gamehistory.history.OriginalGameHistoryQuery
import lab.gamehistory.history.ReadModelGameHistoryQuery
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.batch.core.BatchStatus
import org.springframework.batch.core.job.Job
import org.springframework.batch.core.job.parameters.JobParametersBuilder
import org.springframework.batch.core.launch.JobOperator
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.context.annotation.Import
import org.springframework.core.io.ClassPathResource
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.datasource.init.ScriptUtils
import java.time.Instant
import java.util.UUID
import javax.sql.DataSource

@Import(TestcontainersConfiguration::class)
@SpringBootTest(properties = ["stage3.batch.chunk-size=10"])
class GameHistoryReadModelBatchIntegrationTests {

    @Autowired
    private lateinit var dataSource: DataSource

    @Autowired
    private lateinit var jobOperator: JobOperator

    @Autowired
    private lateinit var gameHistoryReadModelJob: Job

    @Autowired
    private lateinit var jdbcTemplate: JdbcTemplate

    @Autowired
    private lateinit var originalQuery: OriginalGameHistoryQuery

    @Autowired
    private lateinit var readModelQuery: ReadModelGameHistoryQuery

    @BeforeEach
    fun prepareSmallDataSet() {
        dataSource.connection.use { connection ->
            connection.createStatement().use { statement ->
                statement.execute("SET @game_count = 200")
                statement.execute("SET @seed = 20260810")
            }
            ScriptUtils.executeSqlScript(connection, ClassPathResource("stage1-seed.sql"))
            ScriptUtils.executeSqlScript(connection, ClassPathResource("stage2-rebuild-read-model.sql"))
        }
    }

    @Test
    fun buildsTheProjectionInCommittedChunks() {
        jdbcTemplate.update("TRUNCATE TABLE game_history_read_model")

        val execution = jobOperator.start(
            gameHistoryReadModelJob,
            parameters(runId = UUID.randomUUID().toString(), mode = "full"),
        )

        assertEquals(BatchStatus.COMPLETED, execution.status)
        val step = execution.stepExecutions.single()
        assertEquals(200, step.readCount)
        assertEquals(200, step.writeCount)
        assertEquals(20, step.commitCount)
        assertProjectionMatchesSource()
    }

    @Test
    fun restartsTheSameJobInstanceFromTheLastCommittedChunk() {
        jdbcTemplate.update("TRUNCATE TABLE game_history_read_model")
        val runId = UUID.randomUUID().toString()

        val failed = jobOperator.start(
            gameHistoryReadModelJob,
            parameters(runId = runId, mode = "full", failAfterGameId = 55),
        )

        assertEquals(BatchStatus.FAILED, failed.status)
        assertEquals(50, jdbcTemplate.queryForObject("SELECT COUNT(*) FROM game_history_read_model", Long::class.java))
        val failedStep = failed.stepExecutions.single()
        assertEquals(50, failedStep.writeCount)
        assertEquals(5, failedStep.commitCount)
        assertEquals(1, failedStep.rollbackCount)

        val restarted = jobOperator.start(
            gameHistoryReadModelJob,
            parameters(runId = runId, mode = "full"),
        )

        assertEquals(BatchStatus.COMPLETED, restarted.status)
        assertEquals(failed.jobInstanceId, restarted.jobInstanceId)
        assertNotEquals(failed.id, restarted.id)
        val restartedStep = restarted.stepExecutions.single()
        assertEquals(150, restartedStep.readCount)
        assertEquals(150, restartedStep.writeCount)
        assertProjectionMatchesSource()
    }

    @Test
    fun backfillsOnlyTheRequestedGameIdRange() {
        val outsideBefore = jdbcTemplate.queryForObject(
            "SELECT SUM(total_score) FROM game_history_read_model WHERE game_id NOT BETWEEN 40 AND 60",
            Long::class.java,
        )
        jdbcTemplate.update(
            """
                UPDATE round_scores rs
                JOIN rounds r ON r.id = rs.round_id
                SET rs.score = rs.score + 7
                WHERE r.game_id = 50
            """.trimIndent(),
        )

        val execution = jobOperator.start(
            gameHistoryReadModelJob,
            parameters(
                runId = UUID.randomUUID().toString(),
                mode = "backfill",
                minGameId = 40,
                maxGameId = 60,
            ),
        )

        assertEquals(BatchStatus.COMPLETED, execution.status)
        assertEquals(21, execution.stepExecutions.single().writeCount)
        assertEquals(
            outsideBefore,
            jdbcTemplate.queryForObject(
                "SELECT SUM(total_score) FROM game_history_read_model WHERE game_id NOT BETWEEN 40 AND 60",
                Long::class.java,
            ),
        )
        assertProjectionMatchesSource()
    }

    private fun parameters(
        runId: String,
        mode: String,
        minGameId: Long = 1,
        maxGameId: Long = 200,
        failAfterGameId: Long = 0,
    ) = JobParametersBuilder()
        .addString("runId", runId)
        .addString("mode", mode)
        .addLong("minGameId", minGameId)
        .addLong("maxGameId", maxGameId)
        .addLong("failAfterGameId", failAfterGameId, false)
        .toJobParameters()

    private fun assertProjectionMatchesSource() {
        assertEquals(200, jdbcTemplate.queryForObject("SELECT COUNT(*) FROM game_history_read_model", Long::class.java))
        val from = Instant.parse("2025-01-01T00:00:00Z")
        val to = Instant.parse("2026-01-01T00:00:00Z")
        (1L..100L).forEach { shopId ->
            assertEquals(
                originalQuery.findByShopAndPeriod(shopId, from, to, 1000, 0),
                readModelQuery.findByShopAndPeriod(shopId, from, to, 1000, 0),
                "projection differs for shopId=$shopId",
            )
        }
    }
}
