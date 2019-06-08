# Gravity wildcard generator for Pi-hole
This script will generate DNSMASQ wildcards for gravity domains with excessive subdomains.

**Notes**

* DNSMASQ wildcards are completely independent to Pi-hole which means that you are unable to manage them through the Pi-hole interface. If you update your whitelist, for example, you will need to run the script again to make sure that any conflicting wildcards are removed.

* It is recommended to run [gravityOptimise](https://github.com/mmotti/pihole-gravity-optimise) after each run of this script. This will actually remove the unnecessary domains from your gravity table.

* All commands will need to be entered via Terminal (PuTTY or your SSH client of choice) after logging in.

**Example**:
```
pi@raspberrypi:~ $ grep '302br\.net$' /etc/pihole/gravity.list | wc -l
17944
```
This is just one example, returning **17,944** subdomains in my gravity table for **302br.net**

### What does this script do?
1. Updates gravity (`pihole -g`)
2. Fetch gravity domains
3. Identify domains with >= 20 subdomains
4. Exclude wildcards that conflict with the whitelist
5. Determine the blocking mode (NULL, NXDOMAIN, IP-NODATA-AAAA and IP)
6. Output wildcards to DNSMASQ conf file
7. Restart the Pi-hole service

### Can I change the subdomain limit?
Yes! Just edit `limit_subdomains=20` in the script to whatever value you like.

### DNSMASQ preview (NULL blocking mode)
```
pi@raspberrypi:~ $ head -5 /etc/dnsmasq.d/mmotti_generated_wildcards.conf
address=/207.net/#
address=/247realmedia.com/#
address=/2mdn.net/#
address=/2o7.net/#
address=/302br.net/#
```

### Instructions

#### Install
Download the script, copy it to /usr/local/bin/ and give it execution permissions:
```
sudo bash
wget -qO /usr/local/bin/generateGravityWildcards.sh https://raw.githubusercontent.com/mmotti/pihole-gravity-wildcards/master/generateGravityWildcards.sh
chmod +x /usr/local/bin/generateGravityWildcards.sh
exit
```
#### Uninstall
```
sudo bash
rm -f /usr/local/bin/generateGravityWildcards.sh
rm -f /etc/cron.d/generateGravityWildcards
exit
```

#### Manually running the gravityOptimise script
Enter `generateGravityWildcards.sh` in Terminal


#### Create a Cron file (running on a schedule)
This example will run the script every morning at 03:30
1. `sudo nano /etc/cron.d/generateGravityWildcards`
2. Enter: `30 3   * * *   root    PATH="$PATH:/usr/local/bin/" generateGravityWildcards.sh`
3. Press `CTRL` + `X`
4. Press `Y`
5. Press `Enter`