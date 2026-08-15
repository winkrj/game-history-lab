package lab.gamehistory.cdc

import org.apache.kafka.clients.consumer.ConsumerConfig
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.kafka.config.ConcurrentKafkaListenerContainerFactory
import org.springframework.kafka.core.ConsumerFactory
import org.springframework.kafka.listener.CommonContainerStoppingErrorHandler
import org.springframework.kafka.listener.ContainerProperties

@Configuration
@ConditionalOnProperty(name = ["stage5.cdc.enabled"], havingValue = "true")
class Stage5KafkaConsumerConfiguration {

    @Bean
    fun stage5KafkaListenerContainerFactory(
        consumerFactory: ConsumerFactory<String, String>,
    ): ConcurrentKafkaListenerContainerFactory<String, String> {
        val factory = ConcurrentKafkaListenerContainerFactory<String, String>()
        factory.setConsumerFactory(consumerFactory)
        factory.containerProperties.ackMode = ContainerProperties.AckMode.RECORD
        factory.containerProperties.kafkaConsumerProperties[ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG] = false
        factory.setCommonErrorHandler(CommonContainerStoppingErrorHandler())
        return factory
    }
}
