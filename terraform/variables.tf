variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "ami_id" {
  type        = string
  description = "An x86_64 RHEL 9 AMI to which this account is entitled."
}
variable "key_name" {
  type        = string
  description = "Existing EC2 key pair used by the SSH-based Ansible runner."
}
variable "satellite_fqdn" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional unique FQDN. Omit only for a short-lived POC, which uses the EC2 internal FQDN."
  validation {
    condition     = var.satellite_fqdn == null || can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", var.satellite_fqdn))
    error_message = "satellite_fqdn must be a lower-case fully-qualified DNS name when set."
  }
}
variable "hosted_zone_id" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional Route 53 zone ID that contains satellite_fqdn."
  validation {
    condition     = var.hosted_zone_id == null || var.satellite_fqdn != null
    error_message = "hosted_zone_id requires satellite_fqdn."
  }
}
variable "name_prefix" {
  type        = string
  default     = "satellite-poc"
  description = "Prefix for AWS resource names."
}
variable "instance_type" {
  type    = string
  default = "r6i.2xlarge"
}
variable "root_volume_size_gib" {
  type    = number
  default = 100
}
variable "pulp_volume_size_gib" {
  type    = number
  default = 500
}
variable "pulp_volume_type" {
  type    = string
  default = "gp3"
}
variable "pulp_iops" {
  type    = number
  default = 6000
}
variable "pulp_throughput" {
  type    = number
  default = 250
}
variable "admin_cidrs" {
  type        = list(string)
  description = "CIDRs permitted to reach the Satellite HTTPS UI."
}
variable "ssh_cidrs" {
  type        = list(string)
  description = "CIDRs permitted to SSH for the Ansible runner. Keep narrowly scoped."
}
variable "associate_public_ip_address" {
  type    = bool
  default = true
}
variable "tags" {
  type = map(string)
  default = {
    Project   = "satellite-poc"
    ManagedBy = "terraform"
  }
}
