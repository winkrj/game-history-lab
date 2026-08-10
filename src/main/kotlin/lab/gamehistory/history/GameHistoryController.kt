package lab.gamehistory.history

import org.springframework.format.annotation.DateTimeFormat
import org.springframework.http.HttpStatus
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.server.ResponseStatusException
import java.time.Instant

@RestController
@RequestMapping("/shops/{shopId}/games")
class GameHistoryController(
    private val query: OriginalGameHistoryQuery,
) {

    @GetMapping
    fun getGameHistory(
        @PathVariable shopId: Long,
        @RequestParam("from")
        @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME)
        from: Instant,
        @RequestParam("to")
        @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME)
        to: Instant,
        @RequestParam(defaultValue = "0") page: Int,
        @RequestParam(defaultValue = "20") size: Int,
    ): List<GameHistoryResponse> {
        if (shopId <= 0) {
            throw ResponseStatusException(HttpStatus.BAD_REQUEST, "shopId must be positive")
        }
        if (!from.isBefore(to)) {
            throw ResponseStatusException(HttpStatus.BAD_REQUEST, "from must be earlier than to")
        }
        if (page < 0) {
            throw ResponseStatusException(HttpStatus.BAD_REQUEST, "page must not be negative")
        }
        if (size !in 1..MAX_PAGE_SIZE) {
            throw ResponseStatusException(HttpStatus.BAD_REQUEST, "size must be between 1 and $MAX_PAGE_SIZE")
        }

        val offset = page.toLong() * size

        return query.findByShopAndPeriod(
            shopId = shopId,
            fromInclusive = from,
            toExclusive = to,
            limit = size,
            offset = offset,
        ).map { history ->
            GameHistoryResponse(
                gameId = history.gameId,
                shopId = history.shopId,
                playedAt = history.playedAt,
                playerNickname = history.playerNickname,
                courseName = history.courseName,
                totalScore = history.totalScore,
                roundCount = history.roundCount,
                gameStatus = history.gameStatus,
            )
        }
    }

    private companion object {
        const val MAX_PAGE_SIZE = 100
    }
}

data class GameHistoryResponse(
    val gameId: Long,
    val shopId: Long,
    val playedAt: Instant,
    val playerNickname: String,
    val courseName: String,
    val totalScore: Long,
    val roundCount: Long,
    val gameStatus: String,
)

