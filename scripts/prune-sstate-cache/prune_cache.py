#!/usr/bin/python3

import datetime
import os
import sys
import argparse


def num_bytes(N):
    suffix = ["B", "KiB", "MiB", "GiB", "TiB", "UWOT_M8?!?"]
    tmp = float(N)
    for s in suffix:
        if tmp / 1024 < 1.0:
            return tmp, s
        tmp /= 1024
    return tmp, "UWOT?"


def main(args):
    root = os.path.abspath(args.dir)
    try:
        days = int(args.time)
    except ValueError:
        print("Usage: python %s <dir_base> <num_days_old>" % argv[0])
        return

    timelimit = datetime.datetime.now() - datetime.timedelta(days=days)

    objects = []  # (timestamp, path, file_size)
    for path, dirnames, filenames in os.walk(root, topdown=True):
        for filename in filenames:
            file_path = os.path.join(path, filename)
            if os.path.islink(file_path):
                continue
            obj = (
                datetime.datetime.fromtimestamp(os.path.getmtime(file_path)),
                file_path,
                os.path.getsize(file_path),
            )
            objects.append(obj)
        for dirname in dirnames:
            dir_path = os.path.join(path, dirname)
            if os.path.islink(dir_path):
                continue
            obj = None
            if len(os.listdir(dir_path)) == 0:
                obj = (
                    datetime.datetime.fromtimestamp(os.path.getmtime(dir_path)),
                    dir_path,
                    os.path.getsize(dir_path),
                )
            else:
                continue

    objects.sort(key=lambda val: val[0])
    cur_size = sum(f[2] for f in objects)
    sizelimit = cur_size if args.size <= 0 else args.size * (1024 * 1024 * 1024)
    i = 0
    # Loop over file in ascending datetime order and delete files
    # until time and size requirements are satisfied
    while i < len(objects) and (objects[i][0] < timelimit or cur_size > sizelimit):
        print("rm %s" % (objects[i][1]))
        try:
            if os.path.isdir(objects[i][1]):
                os.rmdir(objects[i][1])
            else:
                os.remove(objects[i][1])
        except Exception as e:
            # Supress exceptions
            print(e)
            i += 1
            continue
        cur_size -= objects[i][2]
        i += 1
    sz, suffix = num_bytes(cur_size)
    if i > 0:
        print('New size of "%s": %.2f%s' % (args.dir, sz, suffix))
    else:
        print('No files deleted; size of "%s": %.2f%s' % (args.dir, sz, suffix))


if __name__ == "__main__":

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--time-limit",
        "-t",
        required=True,
        dest="time",
        type=str,
        metavar="DELTA",
        help="Delete files older than DELTA.",
    )
    parser.add_argument(
        "--size-limit",
        "-s",
        required=False,
        dest="size",
        type=int,
        metavar="SIZE",
        help="Hard size limit (in GB), keeps deleting the oldest files "
        + "(regardless of timestamp) until the given max size is reached.",
        default=-1,
    )
    parser.add_argument(
        "--dir",
        "-d",
        required=True,
        dest="dir",
        metavar="PATH",
        help="Path to root directory for which to recursively delete " + "old files",
    )
    args = parser.parse_args()

    os.system("ionice -p %d -c 3" % os.getpid())
    os.nice(10)
    main(args)
