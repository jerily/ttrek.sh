# Install ttrek on Ubuntu with apt

![A penguin pushes a parcel labeled “ttrek” through a mail slot in a terminal window.](images/ttrek-ubuntu-apt.jpg)

On Ubuntu 26.04 LTS, look for a build for your architecture in
[Jerily’s Personal Package Archive (PPA)](https://launchpad.net/~jerily/+archive/ubuntu/ttrek/+packages).

Once the build is listed, add the archive and install ttrek.

```bash
sudo add-apt-repository ppa:jerily/ttrek
sudo apt install ttrek
```

Run `ttrek version` to check the installation. You only need to add the PPA
once. Future ttrek releases from the PPA come through your usual apt upgrades.
