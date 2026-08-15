package lab.gamehistory.batch

import org.springframework.batch.core.BatchStatus
import org.springframework.batch.core.job.Job
import org.springframework.batch.core.job.parameters.JobParametersBuilder
import org.springframework.batch.core.launch.JobOperator
import org.springframework.boot.ApplicationArguments
import org.springframework.boot.ApplicationRunner
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Component

@Component
@ConditionalOnProperty(name = ["stage3.batch.command.enabled"], havingValue = "true")
class Stage3BatchCommand(
    private val jobOperator: JobOperator,
    private val gameHistoryReadModelJob: Job,
    @Value("\${stage3.batch.mode:full}") private val mode: String,
    @Value("\${stage3.batch.run-id:manual}") private val runId: String,
    @Value("\${stage3.batch.min-game-id:1}") private val minGameId: Long,
    @Value("\${stage3.batch.max-game-id:9223372036854775807}") private val maxGameId: Long,
    @Value("\${stage3.batch.fail-after-game-id:0}") private val failAfterGameId: Long,
) : ApplicationRunner {

    override fun run(args: ApplicationArguments) {
        require(mode == "full" || mode == "backfill") { "mode must be full or backfill" }
        require(runId.isNotBlank()) { "run-id must not be blank" }
        require(minGameId > 0) { "min-game-id must be positive" }
        require(maxGameId >= minGameId) { "max-game-id must be greater than or equal to min-game-id" }

        val parameters = JobParametersBuilder()
            .addString("runId", runId)
            .addString("mode", mode)
            .addLong("minGameId", minGameId)
            .addLong("maxGameId", maxGameId)
            .addLong("failAfterGameId", failAfterGameId, false)
            .toJobParameters()

        val execution = jobOperator.start(gameHistoryReadModelJob, parameters)
        execution.stepExecutions.forEach { step ->
            println(
                "STAGE3_STEP name=${step.stepName} status=${step.status} " +
                    "read=${step.readCount} write=${step.writeCount} commit=${step.commitCount} " +
                    "rollback=${step.rollbackCount}",
            )
        }
        println(
            "STAGE3_JOB executionId=${execution.id} instanceId=${execution.jobInstanceId} " +
                "status=${execution.status} exitCode=${execution.exitStatus.exitCode}",
        )

        if (execution.status != BatchStatus.COMPLETED) {
            throw IllegalStateException("Stage 3 batch failed: ${execution.exitStatus.exitDescription}")
        }
    }
}
