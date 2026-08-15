package lab.gamehistory.cdc

data class CdcAffectedGame(
    val gameId: Long,
    val sourceTable: String,
    val operation: String,
    val sourceTimestampMillis: Long?,
)
