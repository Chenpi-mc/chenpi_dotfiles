function seeclip --description='在终端里显示剪贴板中的图片'
    wl-paste -t image/png 2>/dev/null | kitty +kitten icat
    if test $status -ne 0
        echo "剪贴板里没有图片"
        return 1
    end
end
