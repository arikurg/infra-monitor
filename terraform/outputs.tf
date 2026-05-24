output "web_server_public_ip" {
  description = "Permanent public IP of the web server"
  value       = aws_eip.web.public_ip
}

output "app_server_private_ip" {
  description = "Private IP of the app server"
  value       = aws_instance.app.private_ip
}

output "db_server_private_ip" {
  description = "Private IP of the database server"
  value       = aws_instance.db.private_ip
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "ansible_inventory_snippet" {
  description = "Paste this into ansible/inventory.ini"
  value = <<-EOT
    [webservers]
    ${aws_instance.web.public_ip} ansible_user=ec2-user

    [appservers]
    ${aws_instance.app.private_ip} ansible_user=ec2-user

    [dbservers]
    ${aws_instance.db.private_ip} ansible_user=ec2-user
  EOT
}
