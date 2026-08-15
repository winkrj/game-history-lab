package lab.gamehistory.batch

import org.springframework.batch.core.BatchStatus
import org.springframework.batch.core.job.Job
import org.springframework.batch.core.job.parameters.JobParametersBuilder
import org.springframework.batch.core.launch.JobLauncher
import org.springframework.beans.factory.annotation.Qualifier
import org.springframework.beans.factory.annotation.Value
import org.springframework.boot.ApplicationArguments
import org.springframework.boot.ApplicationRunner
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Component
import java.time.Duration
import java.time.LocalDateTime

@Component
@ConditionalOnProperty(name = ["stage4.incremental.command.enabled"], havingValue = "true")
class Stage4IncrementalCommand(
    private val jobLauncher: JobLauncher,
    @Qualifier("incrementalGameHistoryReadModelJob")
    private val incrementalJob: Job,
    private val jdbcTemplate: JdbcTemplate,
    @Value("\${stage4.incremental.run-id:manual}") private val runId: String,
    @Value("\${stage4.incremental.upper-updated-at:}") private val requestedUpperUpdatedAt: String,
    @Value("\${stage4.incremental.overlap-seconds:300}") private val overlapSeconds: Long,
    @Value("\${stage4.incremental.fail-after-count:0}") private val failAfterCount: Long,
) : ApplicationRunner {

    override fun run(args: ApplicationArguments) {
        require(runId.isNotBlank()) { "run-id must not be blank" }
        require(overlapSeconds >= 0) { "overlap-seconds must not be negative" }
        require(failAfterCount >= 0) { "fail-after-count must not be negative" }

        val checkpoint = jdbcTemplate.queryForObject(
            """
                SELECT cursor_updated_at, cursor_game_id
                FROM incremental_read_model_checkpoint
                WHERE checkpoint_name = 'game-history'
            """.trimIndent(),
        ) { resultSet, _ ->
            Cursor(
                updatedAt = resultSet.getObject("cursor_updated_at", LocalDateTime::class.java),
                gameId = resultSet.getLong("cursor_game_id"),
            )
        } ?: error("incremental checkpoint is missing")

        val lowerUpdatedAt = checkpoint.updatedAt.minusSeconds(overlapSeconds)
        val lowerGameId = if (overlapSeconds == 0L) checkpoint.gameId else 0L
        val upperUpdatedAt = if (requestedUpperUpdatedAt.isBlank()) {
            jdbcTemplate.queryForObject("SELECT CURRENT_TIMESTAMP(6)", LocalDateTime::class.java)
                ?: error("database current timestamp is unavailable")
        } else {
            LocalDateTime.parse(requestedUpperUpdatedAt)
        }
        require(!upperUpdatedAt.isBefore(lowerUpdatedAt)) {
            "upper-updated-at must not be before the effective lower bound"
        }

        val parameters = JobParametersBuilder()
            .addString("runId", runId)
            .addLocalDateTime("lowerUpdatedAt", lowerUpdatedAt)
            .addLong("lowerGameId", lowerGameId)
            .addLocalDateTime("upperUpdatedAt", upperUpdatedAt)
            .addLong("upperGameId", Long.MAX_VALUE)
            .addLong("failAfterCount", failAfterCount, false)
            .toJobParameters()

        val startedAt = System.nanoTime()
        val execution = jobLauncher.run(incrementalJob, parameters)
        val durationMillis = Duration.ofNanos(System.nanoTime() - startedAt).toMillis()

        execution.stepExecutions.sortedBy { it.id }.forEach { step ->
            println(
                "STAGE4_STEP name=${step.stepName} status=${step.status} " +
                    "read=${step.readCount} write=${step.writeCount} commit=${step.commitCount} " +
                    "rollback=${step.rollbackCount}",
            )
        }
        println(
            "STAGE4_JOB executionId=${execution.id} instanceId=${execution.jobInstanceId} " +
                "status=${execution.status} lowerUpdatedAt=$lowerUpdatedAt lowerGameId=$lowerGameId " +
                "upperUpdatedAt=$upperUpdatedAt durationMs=$durationMillis",
        )

        if (execution.status != BatchStatus.COMPLETED) {
            throw IllegalStateException("Stage 4 incremental batch failed: ${execution.exitStatus.exitDescription}")
        }
    }

    private data class Cursor(
        val updatedAt: LocalDateTime,
        val gameId: Long,
    )
}
