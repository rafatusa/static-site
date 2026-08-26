output "public_ip" {
  description = "Public address of the application server."
  value       = aws_eip.app.public_ip
}
