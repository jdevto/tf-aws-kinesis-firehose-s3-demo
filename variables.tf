variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "kinesis-firehose-demo"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}
