package lab.gamehistory.batch

import lab.gamehistory.projection.GameHistoryProjectionUpdater
import org.springframework.batch.infrastructure.item.Chunk
import org.springframework.batch.infrastructure.item.ItemWriter

class IncrementalReadModelWriter(
    private val projectionUpdater: GameHistoryProjectionUpdater,
) : ItemWriter<IncrementalSourceChange> {

    override fun write(chunk: Chunk<out IncrementalSourceChange>) {
        projectionUpdater.upsertGames(chunk.items.map { it.gameId })
    }
}
