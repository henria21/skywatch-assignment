output "master_public_ip"  { value = aws_instance.node["master"].public_ip }
output "worker2_public_ip" { value = aws_instance.node["worker2"].public_ip }
