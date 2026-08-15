package lab.gamehistory.batch

import java.time.LocalDateTime

data class IncrementalSourceChange(
    val gameId: Long,
    val changedAt: LocalDateTime,
)
