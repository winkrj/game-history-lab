package lab.gamehistory.cdc

import org.springframework.beans.factory.annotation.Value
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.stereotype.Component
import java.util.concurrent.atomic.AtomicBoolean

@Component
@ConditionalOnProperty(name = ["stage5.cdc.enabled"], havingValue = "true")
class CdcFailureInjector(
    @Value("\${stage5.cdc.fail-on-game-id:0}") private val failOnGameId: Long,
) {

    private val failureInjected = AtomicBoolean(false)

    fun afterProjectionUpdate(gameId: Long) {
        if (gameId == failOnGameId && failureInjected.compareAndSet(false, true)) {
            throw IllegalStateException("Deterministic CDC failure for gameId=$gameId")
        }
    }
}
