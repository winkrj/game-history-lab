package lab.gamehistory.cdc

import lab.gamehistory.projection.GameHistoryProjectionUpdater
import org.apache.kafka.clients.consumer.ConsumerRecord
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.kafka.annotation.KafkaListener
import org.springframework.stereotype.Component
import org.springframework.transaction.annotation.Transactional
import org.springframework.transaction.support.TransactionSynchronization
import org.springframework.transaction.support.TransactionSynchronizationManager
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean

@Component
@ConditionalOnProperty(name = ["stage5.cdc.enabled"], havingValue = "true")
class GameHistoryCdcConsumer(
    private val affectedGameResolver: CdcAffectedGameResolver,
    private val projectionUpdater: GameHistoryProjectionUpdater,
    @Value("\${stage5.cdc.fail-on-game-id:0}") private val failOnGameId: Long,
) {

    private val failureInjected = AtomicBoolean(false)

    @KafkaListener(
        topics = [
            "\${stage5.cdc.topic.games:game-history.game_history_lab.games}",
            "\${stage5.cdc.topic.rounds:game-history.game_history_lab.rounds}",
            "\${stage5.cdc.topic.round-scores:game-history.game_history_lab.round_scores}",
        ],
        containerFactory = "stage5KafkaListenerContainerFactory",
    )
    @Transactional("transactionManager")
    fun consume(record: ConsumerRecord<String, String>) {
        val affectedGame = affectedGameResolver.resolve(record.value()) ?: return
        val receivedAtMillis = Instant.now().toEpochMilli()

        projectionUpdater.upsertGames(listOf(affectedGame.gameId))
        if (affectedGame.gameId == failOnGameId && failureInjected.compareAndSet(false, true)) {
            throw IllegalStateException("Deterministic CDC failure for gameId=${affectedGame.gameId}")
        }

        TransactionSynchronizationManager.registerSynchronization(
            object : TransactionSynchronization {
                override fun afterCommit() {
                    val visibleAtMillis = Instant.now().toEpochMilli()
                    logger.info(
                        "STAGE5_CDC_APPLIED topic={} partition={} offset={} table={} operation={} " +
                            "gameId={} sourceTsMs={} receivedAtMs={} visibleAtMs={}",
                        record.topic(),
                        record.partition(),
                        record.offset(),
                        affectedGame.sourceTable,
                        affectedGame.operation,
                        affectedGame.gameId,
                        affectedGame.sourceTimestampMillis,
                        receivedAtMillis,
                        visibleAtMillis,
                    )
                }
            },
        )
    }

    private companion object {
        val logger = LoggerFactory.getLogger(GameHistoryCdcConsumer::class.java)
    }
}
