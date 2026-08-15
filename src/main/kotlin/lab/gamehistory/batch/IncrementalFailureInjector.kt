package lab.gamehistory.batch

import org.springframework.batch.infrastructure.item.ItemProcessor
import java.util.concurrent.atomic.AtomicLong

class IncrementalFailureInjector(
    private val failAfterCount: Long,
) : ItemProcessor<IncrementalSourceChange, IncrementalSourceChange> {

    private val processedCount = AtomicLong()

    override fun process(item: IncrementalSourceChange): IncrementalSourceChange {
        val currentCount = processedCount.incrementAndGet()
        if (failAfterCount > 0 && currentCount >= failAfterCount) {
            throw IllegalStateException(
                "Deterministic incremental failure after count=$currentCount gameId=${item.gameId}",
            )
        }
        return item
    }
}
