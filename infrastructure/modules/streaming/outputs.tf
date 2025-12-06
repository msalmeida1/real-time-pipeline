output "stream_arn" {
  value = aws_kinesis_stream.music_stream.arn
}

output "stream_name" {
  value = aws_kinesis_stream.music_stream.name
}
