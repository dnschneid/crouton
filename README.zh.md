# Crouton中文版教程

> 基于crouton项目README的英文版进行汉化，部分内容没有进行汉化，建议有能力者优先阅读英文版本。

## 简介

​	Chroot是Chromium OS Universal Chroot Environment 的简写，是一系列脚本的合集，利用Linux的Chroot，在Chromebook上同时运行Chrome OS和某个Linux发行版。

## Chroot介绍

​	Chroot命令用来在指定的根目录下运行指令。Chroot的这种功能可以为第二系统提供一个隔离的文件系统，就像虚拟化一样，但是第二系统实际上仍然在主系统的文件系统下面工作，在进程和网络层面，chroot并没有进行隔离。

​	至于详细的内容，为什么不去问问[百度搜索](https://www.baidu.com/s?wd=chroot)？

## 进入正题

### 环境

- **良好的**网络环境
- 进入**开发者模式**的Chromebook，相关操作请进入[这个页面](https://www.chromium.org/chromium-os/developer-information-for-chrome-os-devices)（英文页面），点击对应的设备型号，按照*Entering Developer Mode*章节的步骤进行
- 强烈建议安装[Crouton插件](https://goo.gl/OVQOEt)，配合`extension`或者`xiwi`目标，可以提高第二系统与Chrome OS之间的交互体验

### 用法

1. 你需要从[这里](https://goo.gl/fd3zc)下载Crouton脚本。~~什么？下不下来？关我什么事~~

2. 然后打开shell（`ctrl+alt+T`,在打开的窗口中输入`shell`，然后回车）。

3. 输入`sudo install -Dt /usr/local/bin -m 755 ~/Downloads/crouton`，这一步是将下载下来的脚本安装到`/usr/local/bin`这个可执行目录里面。

4. `sudo crouton`可以查看帮助，本教程**示例**部分会有一些命令使用举例。

   如果你想对Crouton稍作修改，可以将本项目下载到`/usr/local`，直接运行`installer/main.sh`或者使用`make`进行编译。你也可以按上述四步安装crouton后，使用`crouton -x`将包含的脚本解压，不过那样的话你需要自己编写编译所需的文件，以及记住脚本所在的位置。

   Crouton使用“目标”('targets')来决定安装什么。可用的目标可以运行`crouton -t help`来查看。

   安装之后，可以输入`enter-chroot`，或者由你选择的安装目标所决定的 start* 命令。具体的命令，安装完成后终端会有介绍（英文）。  

## 示例

**简单示例（安装Ubuntu LTS，使用Xfce桌面环境）**

1. 下载Crouton
2. 打开shell（`ctrl+alt+T`,在打开的窗口中输入`shell`，然后回车）。
3. 输入`sudo install -Dt /usr/local/bin -m 755 ~/Downloads/crouton`
4. `sudo crouton -t xfce`
5. 等吧，可以喝杯星巴克
6. 安装完成后，使用`sudo enter-chroot startxfce4`，或者`sudo startxfce4`运行chroot，会自动跳至Xfce
7. 登出/注销(logout)Xfce来退出chroot，**在Xfce里点击关机是没有用的**。

**加密**

1. 运行crouton是可以添加`-e`参数来创建一个加密的chroot环境，或者加密一个未加密的chroot环境
2. 使用`-k`参数来指定储存密钥的路径

**想用别的系统？**

1. `-r`参数可以指定你想要使用的发行版和版本代号
2. `crouton -r list`可以查看支持的发行版和版本代号（英文）

**说好的“更好的交互体验”？**

1. 在Chrome OS安装[Crouton插件](https://goo.gl/OVQOEt)

2. 在chroot环境中添加`extension`或者`xiwi`目标

   这样可以同步chroot环境和主系统的剪贴板，允许chroot环境的程序在Chrome OS界面中窗口化运行。

**只使用命令行**

1. 指定安装目标时可以只使用`-t core`或者`-t cli-extra`
2. 使用`sudo enter-chroot`进入chroot环境
3. 使用[Crosh Window插件](https://goo.gl/eczLT)，防止chroot命令行环境导致的快捷键失效

**升级chroot环境**

​	使用`sudo crouton -u -n chrootname`来升级chroot环境中的系统。

**安装后想添加一些安装目标？**

​	使用`-u`参数来添加安装目标。

​	比如，添加`xiwi`目标：`sudo crouton -t xiwi -u -n chrootname`

​	上述命令会让xiwi成为默认的[X窗口方法](https://baike.baidu.com/item/X%E7%AA%97%E5%8F%A3/1471357?fr=aladdin)（原默认方法为xorg），如果想让X窗口方法继续保持默认：

​	`sudo crouton -t xorg,xiwi -u -n chrootname`

**备份**

​	`sudo edit-chroot -b chrootname`会在命令运行目录下生成chroot环境的tar格式的备份文件（带备份时间戳），Chroot环境的名字可以在安装时由`-n`参数指定，未指定时默认为所安装的Linux发行版版本代号（例如，默认的Ubuntu 16.04LTS版本代号为xenial）

​	`sudo edit-chroot -r chrootname`默认恢复最近一次的备份文件。可以用`-r`参数指定恢复文件

​	对全新或者重置过的电脑，可以使用Crouton的恢复命令：`sudo crouton -f mybackup.tar.gz`

**更改安装位置**

​	`-p`参数可指定chroot的安装位置。

​	每次启动电脑后第一次启动chroot，请确定chroot的安装位置是可执行（executable）的：

	1. 确定挂载点：`df --output=target /path/to/enterchroot`
 	2. 使挂载点可读写：`sudo mount -o remount,exec /path/to/mountpoint`

**删除Chroot环境**

​	`sudo delete-chroot chrootname`

## 使用提醒

- 使用`-n`来指定Chroot环境的名字，可以创建多个chroot环境
- 使用`-m`参数更改镜像源
- `-P`参数开启/关闭Chroot环境的代理，仅支持http/https
- chroot内置`brightness`脚本，可以：
  - 调节屏幕亮度（比如，在chroot内运行`brightness up`）
  - 调节背光键盘亮度（比如，在chroot内运行：`brightness k down`）
- 使用多屏可能需要先切换到Chrome OS界面，然后再切换回来
- 运行命令添加`-b`参数可以让chroot在后台运行，比如：`sudo startxfce4 -b`
- `croutonpowerd -i`可以关闭Chrome OS的电源管理
- `croutonpowerd -i command and arguments`可以指定在chroot执行某些命令时关闭Chrome OS的电源管理
- `touch`安装目标可以改善触摸屏设备的使用体验
- 本项目Wiki中有关于文件共享的介绍
- [Wiki](https://github.com/dnschneid/crouton/wiki)中也有更多其他提示（英文）
