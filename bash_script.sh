#!/bin/bash
# This script generates a Vagrantfile to set up a master and a slave node with a LAMP stack.
# A Nginx load balancer is configured on the master node.
# Post setup, the script also validates PHP functionality with Apache on both nodes.

# Generate Vagrantfile
cat <<EOF > Vagrantfile
# Define the virtual environment configuration using Vagrant's DSL (Domain Specific Language).
Vagrant.configure("2") do |config|

  # Master Node Configuration
  config.vm.define "master" do |master|
    # Define the box (base image) and its version
    master.vm.box = "spox/ubuntu-arm"
    master.vm.box_version = "1.0.0"
    # Set up a private network with the specified IP
    master.vm.network "private_network", ip: "192.168.56.11"
    # Configure the VM provider, in this case, VMware
    master.vm.provider "vmware_desktop" do |vmware|
      vmware.gui = true
      vmware.allowlist_verified = true
    end
    master.vm.hostname = 'master'
    # Inline provisioning script to configure the node
    master.vm.provision "shell", inline: <<-SHELL
      # Create a new user named 'altschool' and set its password
      sudo useradd -m -s /bin/bash altschool
      echo "altschool:password" | sudo chpasswd
      # Provide 'altschool' with sudo privileges without password prompt
      echo "altschool ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/altschool
      
      # Ensure the .ssh directory exists for 'altschool' with the right permissions
      sudo -u altschool mkdir -p /home/altschool/.ssh
      sudo -u altschool chmod 700 /home/altschool/.ssh
      
      # Generate an SSH key pair for 'altschool'
      sudo -u altschool ssh-keygen -t rsa -f /home/altschool/.ssh/id_rsa -N ""
      sudo -u altschool chmod 600 /home/altschool/.ssh/id_rsa

      # Create a directory at /mnt/altschool and assign ownership to 'altschool'
      sudo mkdir /mnt/altschool
      sudo chown -R altschool:altschool /mnt/altschool/

      # Install sshpass for password-based SSH authentication
      sudo apt-get update && sudo apt-get install -y sshpass

      # Use sshpass to transfer the SSH public key to the slave node for password-less login
      sudo -u altschool bash -c 'sshpass -p "password" ssh-copy-id -o StrictHostKeyChecking=no -i /home/altschool/.ssh/id_rsa.pub altschool@192.168.56.12'

      # Install the LAMP stack components
      sudo apt-get install -y apache2 mysql-server php libapache2-mod-php php-mysql

      # Start and enable the Apache service
      sudo systemctl start apache2
      sudo systemctl enable apache2

      # Create a PHP file to display PHP's configuration for validation purposes
      echo "<?php phpinfo(); ?>" | sudo tee /var/www/html/info.php
    SHELL
  end

  # Slave Node Configuration
  config.vm.define "slave" do |slave|
    slave.vm.box = "spox/ubuntu-arm"
    slave.vm.box_version = "1.0.0"
    slave.vm.network "private_network", ip: "192.168.56.12"
    slave.vm.provider "vmware_desktop" do |vmware|
      vmware.gui = true
      vmware.allowlist_verified = true
    end
    slave.vm.hostname = 'slave'
    slave.vm.provision "shell", inline: <<-SHELL
      # Similar user setup and .ssh directory creation for the slave node as seen for master
      sudo useradd -m -s /bin/bash altschool
      echo "altschool:password" | sudo chpasswd
      echo "altschool ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/altschool

      sudo mkdir /mnt/altschool
      sudo chown -R altschool:altschool /mnt/altschool/
      sudo -u altschool mkdir -p /mnt/altschool/slave
      sudo -u altschool mkdir -p /home/altschool/.ssh
      sudo -u altschool touch /home/altschool/.ssh/authorized_keys

      # Configure SSHD to allow RSA authentication and public key authentication
      sudo sed -i 's/#\?RSAAuthentication.*/RSAAuthentication yes/' /etc/ssh/sshd_config
      sudo sed -i 's/#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
      sudo systemctl restart sshd

      # Ensure correct permissions for the .ssh directory and its contents
      sudo chown -R altschool:altschool /home/altschool/.ssh
      sudo chmod 700 /home/altschool/.ssh
      sudo chmod 600 /home/altschool/.ssh/authorized_keys

      # Install the LAMP stack components for the slave node
      sudo apt-get update && sudo apt-get install -y apache2 mysql-server php libapache2-mod-php php-mysql

      # Start and enable the Apache service
      sudo systemctl start apache2
      sudo systemctl enable apache2

      # Create a PHP file to display PHP's configuration for validation on the slave node
      echo "<?php phpinfo(); ?>" | sudo tee /var/www/html/info.php
    SHELL
  end
end
EOF

# Start and provision the VMs. We start the slave first since the master tries to transfer SSH keys to the slave.
vagrant up slave
sleep 60
vagrant up master
sleep 60

# Test SSH from master to slave
vagrant ssh master -- -t "sudo -u altschool ssh -o StrictHostKeyChecking=no -i /home/altschool/.ssh/id_rsa altschool@192.168.56.12 echo 'Slave connection confirmed!'"

# Disable password authentication for SSH on the slave for security
vagrant ssh slave -- -t "sudo sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"

# Set up nginx load balancer on master
echo "LAMP stack installed and configured on both nodes."

# Validate PHP functionality with Apache
echo "Testing PHP functionality with Apache on both nodes..."

# Create a PHP test file
php_test_file="<?php phpinfo(); ?>"

vagrant ssh master -c "echo '$php_test_file' > test-master.php"
vagrant ssh master -c "sudo mv test-master.php /var/www/html/"

vagrant ssh slave -c "echo '$php_test_file' > test-slave.php"
vagrant ssh slave -c "sudo mv test-slave.php /var/www/html/"

echo "Access the following URLs to validate PHP setup:"
echo "Master node: http://192.168.56.11/test-master.php"
echo "Slave node: http://192.168.56.12/test-slave.php"

echo "Setting up Nginx load balancer on master node..."
vagrant ssh master -c "sudo apt-get update && sudo apt-get install -y nginx"
vagrant ssh master -c "sudo systemctl start nginx"
vagrant ssh master -c "sudo systemctl enable nginx"

nginx_config="events {}
http {
    upstream backend {
        server 192.168.56.11;
        server 192.168.56.12;
    }

    server {
        listen 80;
        location / {
            proxy_pass http://backend;
        }
    }
}"

vagrant ssh master -c "echo '$nginx_config' | sudo tee /etc/nginx/sites-available/load_balancer"
vagrant ssh master -c "sudo ln -s /etc/nginx/sites-available/load_balancer /etc/nginx/sites-enabled/"
vagrant ssh master -c "sudo systemctl restart nginx"

echo "Nginx load balancer is now set up. Access the master node at http://192.168.56.11 to see the load-balanced output."

echo "Setup is complete!"

echo "NB: chmod +x bash_script.sh before running this script"
# Instructions for post-deployment tasks:
echo "--------------------------------------"
echo "POST DEPLOYMENT TASKS"
echo "--------------------------------------"
echo "1. To SSH into the master node:"
echo "   $ vagrant ssh master"
echo
echo "2. Check Apache's status on master:"
echo "   $ vagrant ssh master -- -t 'sudo systemctl status apache2'"
echo
echo "3. To SSH into the slave node from the master node:"
echo "   - First SSH into the master: $ vagrant ssh master"
echo "   - Then SSH to the slave: $ sudo -u altschool ssh -o StrictHostKeyChecking=no -i /home/altschool/.ssh/id_rsa altschool@192.168.56.12"
echo
echo "4. Check Apache's status on slave from master:"
echo "   $ vagrant ssh master -- -t 'sudo -u altschool ssh -o StrictHostKeyChecking=no -i /home/altschool/.ssh/id_rsa altschool@192.168.56.12 \"sudo systemctl status apache2\"'"
echo
echo "5. To halt (turn off) the VMs when done:"
echo "   $ vagrant halt"
echo
echo "6. To destroy and remove the VMs completely:"
echo "   $ vagrant destroy -f"
echo "--------------------------------------"

