package lab.gamehistory.history

import java.time.Instant

data class GameHistoryResult(
    val gameId: Long,
    val shopId: Long,
    val playedAt: Instant,
    val playerNickname: String,
    val courseName: String,
    val totalScore: Long,
    val roundCount: Long,
    val gameStatus: String,
)
