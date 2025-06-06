variable "region" {
  type        = string
  description = "AWS region"
}

variable "origin_domain_name" {
  type        = string
  description = "(Required) - The DNS domain name of your custom origin (e.g. website)"
  default     = ""
}

variable "origin_type" {
  type        = string
  default     = "s3"
  description = "The type of origin configuration to use. Valid values are 'custom' or 's3'."
}

variable "logging_enabled" {
  type        = bool
  default     = false
  description = "When true, access logs will be sent to a newly created s3 bucket"
}
